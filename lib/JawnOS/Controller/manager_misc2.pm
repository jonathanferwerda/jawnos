package Manager;

# manager_misc2: route actions moved out of Manager.pl, one sub per route so a
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
use Digest::SHA qw(sha1_hex);
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

# POST /manager/magazine/publishing_receive
sub action_7112 {
	my $c = shift;
	my $articles = eval { return decode_json $c->param('articles') } || {};
	my $nonpublished = eval { return decode_json $c->param('nonpublished') };
	my $timestamp = &subs::rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	foreach my $a ( @{$articles} ) {
		# A publish can arrive from a resident or a peer, so its content is
		# untrusted exactly like an editor save: clean it before it is stored.
		$a->{'content'} = &subs::article_html_clean($a->{'content'}) if exists $a->{'content'};
		my $q = &subs::db_query('select * from magazine where uuid=?', $a->{'uuid'});
		my $prev = $q->hashes;
		my $category = &subs::setting_grabber({ app => $a->{'category'}, setting => 'pos' });
		unless ($category eq 'category') {
			my $pillow = &subs::unformat_name($a->{'category'} . ' category');
			my $init = &subs::setting_initializer($pillow,$timestamp);
			$a->{'category'} = $init->{'app'};
			my $ass = &appointment_writer($c,{
				app => $a->{'category'},
				type => 'text',
				timestamp => $timestamp,
			});
		}
		if ($prev->[0]->{'uuid'}) {
			&subs::db_update('magazine', $a, { uuid => $a->{'uuid'} });
		}
		else {
			my $insert = &subs::db_insert('magazine', $a);
		}
	}
	foreach my $a (@{$nonpublished}) {
		&subs::db_query('update magazine set status=? where uuid=?', $a->{'status'}, $a->{'uuid'});
	}
	$c->render('text' => 'success');
}

# POST /manager/editor/save
sub action_7170 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $scope = $c->param('scope');
	my $server_time = &subs::rightNow();
	my $title = $c->param('title');
	my $content = &subs::article_html_clean($c->param('content'));
	my $teaser = &subs::teaser_name($c->param('teaser')) . '...' || "";
	my $uuid = $c->param('article_uuid');
	my $text_colour = $c->param('text_colour');
	my $background_colour = $c->param('background_colour');
	my $status = $c->param('status');
	my $category = $c->param('category');
	my $image = $c->param('image');
	my $warranty = &subs::ago_calc($c->param('warranty') || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time);
	my $previous_edition;
	if ($uuid ne 'none') {
		my $previous_editionq = &subs::db_query('select * from magazine where uuid=?', $uuid);
		$previous_edition = $previous_editionq->hashes->[0];

	}
	my $timestamp = &subs::ago_calc($c->param('timestamp'), $server_time) || $server_time;


	my $article = {
		uuid => $uuid,
		title => $title,
		content => $content,
		timestamp => $timestamp,
		manager_file => &manager_file_maker($c->session('name')),
		status => $status,
		text_colour => $text_colour,
		background_colour => $background_colour,
		server_time => $server_time,
		category => $category,
		warranty => $warranty,
		image => $image,
		teaser => $teaser
	};
	if (!$previous_edition->{'uuid'} || $uuid eq 'none') {
		$article->{'uuid'} = &subs::random_string_creator(100);
		$uuid = $article->{'uuid'};
		&subs::db_insert('magazine', $article);
	}
	else {
		&subs::db_update('magazine', $article, { uuid => $uuid });
	}
	if (($status ne 'publish') || ( $timestamp >= $server_time || $warranty <= $server_time )) {
		&paperRoute({ uuid => $article->{'uuid'}, remove => 'yes' });
	}
	elsif ($status eq 'publish') {
		$article->{'art'} = $c->render_to_string(template => 'article', art => $article);
		&paperRoute($article);
	}
	$c->render(json => { uuid => $uuid });
}

# POST /manager/editor/delete
sub action_7226 {
	my $c = shift;
	my $uuid = $c->param('article_uuid');
	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::db_query('delete from magazine where uuid = ?', $uuid);
	$c->render('text' => 'ok');
}

# GET /manager/debrief_grabber
sub action_7767 {
	my $c = shift;
	# a debrief is this browser's own store - personal data. Only an authenticated
	# session gets it back, and only its own ticket's snapshot; anyone at the gate
	# gets nothing.
	unless ($c->session('authentication') eq 'approved' && $c->session('ticket_uuid')) {
		$c->render(json => {});
		return;
	}
	my $ticket_uuid = $c->session('ticket_uuid');
	$c->render(json => &subs::debrief_read($ticket_uuid));
}

# POST /manager/fuck_you
sub action_7783 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	&Websocket::send('server',{ not_me => 1, browser_tab_id => $c->param('browser_tab_id'), 'console' => 'fuck_you();', timestamp => $timestamp });
	$c->render('text' => 'fuck yeah!');
}

# GET /manager/network
sub action_7845 {
	my $c = shift;
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	# The Controller partial is included, so its sockets must ride the stash
	# rather than a lexical in the parent template.
	my $browser_tab_id = $c->param('browser_tab_id') || '';
	my $websockets = eval { &subs::db_query('select * from websockets where browser_tab_id = ?', $browser_tab_id)->hashes } || [];
	my $content = $c->render_to_string(template => 'apps/network', websockets => $websockets);
	my $contents = &window_maker({
		user_agent => $c->param('user_agent'),
		app => 'network',
		title => &subs::lang('network'),
		contents => $content
	}, $timestamp);
	$c->render(text => $contents);
}

# GET /manager/controller/snapshot
# The Controller's first paint. The heartbeat saves the last full picture for
# Music, Server and Tab in the house's cache; this hands it back at once, so
# opening the tab does not wait for the next socket beat. The live beat follows
# and replaces it.
sub action_7846 {
	my $c = shift;
	my %beats;
	my $browser_tab_id = $c->param('browser_tab_id') || '';
	if (length $browser_tab_id) {
		# Same digest the beat writes: one cache row per app, per browser tab.
		my $key = 't' . substr(sha1_hex($browser_tab_id), 0, 24);
		foreach my $app ( qw/music server tab/ ) {
			my $snap = &subs::cache_get({ app => 'controller', context => 'beat_' . $app, subcontext => $key });
			$beats{$app} = $snap if ref $snap eq 'HASH';
		}
	}
	$c->render(json => { beats => \%beats });
}

# GET /manager/network/bluetooth/status
sub action_7849 {
	my $c = shift;
	my $answer = eval { &bluetooth_helper(['status']) };
	$answer = { ok => 0, error => 'The Bluetooth status could not be read.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/bluetooth/scan
sub action_7852 {
	my $c = shift;
	my $state = $c->param('state') // '';
	unless ($state =~ /^(?:on|off)$/) {
		$c->render(json => { ok => 0, error => 'Scanning can only be turned on or off.' });
		return;
	}
	my $answer = eval { &bluetooth_helper(['scan', $state]) };
	$answer = { ok => 0, error => 'The scan could not be run.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/bluetooth/action
sub action_7855 {
	my $c = shift;
	my $action = $c->param('action') // '';
	my $answer;
	if ($action eq 'power') {
		my $state = $c->param('state') // '';
		unless ($state =~ /^(?:on|off)$/) {
			$c->render(json => { ok => 0, error => 'The adapter can only be turned on or off.' });
			return;
		}
		$answer = eval { &bluetooth_helper(['power', $state]) };
	}
	else {
		my $address = $c->param('address') // '';
		unless ($action =~ /^(?:pair|connect|disconnect|trust|remove)$/) {
			$c->render(json => { ok => 0, error => 'The Bluetooth action is not valid.' });
			return;
		}
		unless ($address =~ /^[0-9A-Fa-f:]{17}$/) {
			$c->render(json => { ok => 0, error => 'That device address is not valid.' });
			return;
		}
		$answer = eval { &bluetooth_helper([$action, $address]) };
	}
	$answer = { ok => 0, error => 'The Bluetooth request could not be completed.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# GET /manager/network/status
sub action_7857 {
	my $c = shift;
	my $answer = eval { &network_helper(['status']) };
	$answer = { ok => 0, error => 'The network status could not be read.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/wifi_scan
sub action_7863 {
	my $c = shift;
	my $interface = $c->param('interface') // '';
	if (length $interface && $interface !~ /^[A-Za-z0-9_.:-]{1,32}$/) {
		$c->render(json => { ok => 0, error => 'That interface name is not valid.' });
		return;
	}
	my $answer = eval { &network_helper(['wifi_scan', $interface]) };
	$answer = { ok => 0, error => 'The scan could not be run.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/wifi_connect
sub action_7874 {
	my $c = shift;
	my $interface = $c->param('interface') // '';
	my $ssid = $c->param('ssid') // '';
	my $passphrase = $c->param('passphrase') // '';
	my $error;
	$error = 'That interface name is not valid.' unless $interface =~ /^[A-Za-z0-9_.:-]{1,32}$/;
	$error = 'That network name is not valid.'
		unless $error || (length $ssid && length($ssid) <= 32 && $ssid !~ /[\x00-\x1f\x7f]/);
	$error = 'The passphrase must be 8 to 63 printable characters, or 64 hexadecimal digits.'
		if !$error && length $passphrase
			&& !($passphrase =~ /^[\x20-\x7e]{8,63}$/ || $passphrase =~ /^[0-9A-Fa-f]{64}$/);
	if ($error) {
		$c->render(json => { ok => 0, error => $error });
		return;
	}
	my $answer = eval { &network_helper(['wifi_connect', $interface, $ssid], $passphrase) };
	$answer = { ok => 0, error => 'The connection could not be attempted.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/wifi_disconnect
sub action_7894 {
	my $c = shift;
	my $forget = $c->param('forget') // '';
	my $answer;
	if ($forget eq '1') {
		my $ssid = $c->param('ssid') // '';
		unless (length $ssid && length($ssid) <= 32 && $ssid !~ /[\x00-\x1f\x7f]/) {
			$c->render(json => { ok => 0, error => 'That network name is not valid.' });
			return;
		}
		$answer = eval { &network_helper(['wifi_forget', $ssid]) };
	}
	else {
		my $interface = $c->param('interface') // '';
		unless ($interface =~ /^[A-Za-z0-9_.:-]{1,32}$/) {
			$c->render(json => { ok => 0, error => 'That interface name is not valid.' });
			return;
		}
		$answer = eval { &network_helper(['wifi_disconnect', $interface]) };
	}
	$answer = { ok => 0, error => 'The request could not be completed.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/radio
sub action_7917 {
	my $c = shift;
	my $state = $c->param('state') // '';
	unless ($state =~ /^(?:on|off)$/) {
		$c->render(json => { ok => 0, error => 'The radio can only be turned on or off.' });
		return;
	}
	my $answer = eval { &network_helper(['radio', $state]) };
	$answer = { ok => 0, error => 'The radio could not be changed.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/interface
sub action_7928 {
	my $c = shift;
	my $action = $c->param('action') // '';
	my $name = $c->param('name') // '';
	unless ($action =~ /^(?:up|down)$/ && $name =~ /^[A-Za-z0-9_.:-]{1,32}$/) {
		$c->render(json => { ok => 0, error => 'The interface action is not valid.' });
		return;
	}
	my $answer = eval { &network_helper(['interface', $action, $name]) };
	$answer = { ok => 0, error => 'The interface could not be changed.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/vpn
sub action_7940 {
	my $c = shift;
	my $action = $c->param('action') // '';
	my $answer;
	if ($action eq 'tailscale_up' || $action eq 'tailscale_down') {
		$answer = eval { &network_helper(['vpn_tailscale', $action eq 'tailscale_up' ? 'up' : 'down']) };
	}
	elsif ($action eq 'vpn_start' || $action eq 'vpn_stop') {
		my $kind = $c->param('kind') // '';
		my $name = $c->param('name') // '';
		unless ($kind =~ /^(?:wg|openvpn)$/ && $name =~ /^[A-Za-z0-9_=+.-]{1,64}$/) {
			$c->render(json => { ok => 0, error => 'The VPN configuration is not valid.' });
			return;
		}
		$answer = eval { &network_helper(['vpn_unit', $action eq 'vpn_start' ? 'start' : 'stop', $kind, $name]) };
	}
	else {
		$c->render(json => { ok => 0, error => 'The VPN action is not valid.' });
		return;
	}
	$answer = { ok => 0, error => 'The VPN request could not be completed.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# GET /manager/network/public_ip
#
# This machine's own globally routable address, read from its interfaces: no
# outbound request and nothing to cache. A machine behind NAT has none, and
# says so rather than guessing at the router's address.
sub action_7943 {
	my $c = shift;
	my $answer = eval { &network_helper(['public_ip']) };
	$answer = { ok => 0, error => 'The public address could not be read.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/network/public_ip_lookup
#
# The outward address behind NAT can only be learned from outside, so this is a
# separate, explicit request (the panel's Look up button) and the answer is
# cached for ten minutes. A failure is not cached, so a later press retries.
sub action_7944 {
	my $c = shift;
	my $cached = eval { &subs::cache_get({ app => 'network', context => 'public_ip_lookup' }) };
	if (ref $cached eq 'HASH' && $cached->{'ok'} && ($cached->{'at'} || 0) > &subs::rightNow() - 600000) {
		$c->render(json => $cached);
		return;
	}
	my $answer = eval { &network_helper(['public_ip_lookup']) };
	$answer = { ok => 0, error => 'The public address could not be read.' } unless ref $answer eq 'HASH';
	if ($answer->{'ok'}) {
		$answer->{'at'} = &subs::rightNow();
		eval { &subs::cache_set({ app => 'network', context => 'public_ip_lookup', warranty => '-15m' }, $answer) };
	}
	$c->render(json => $answer);
}

# GET /manager/time_jump
sub action_7994 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $filter = $c->param('filter');
	my $type = $c->param('type');
	my $app = $c->param('app');
	my $scope = $c->param('scope');
	my $t = &subs::time_span($scope, $timestamp); #timestamp at beginning
	my $t1 = ($timestamp - $t);
	my $t2 = ($t1 + $timestamp + $t1);
	my $query;
	my $date = localtime( time() )->strftime('%a %B %d %Y %I:%M%P');
	# cast: the column is text, so a plain < compares lexicographically and finds
	# nothing once the view is before 1970 (a negative timestamp)
	if ($type eq 'prev') {
		if ($filter ne 'all') {
			$query = &subs::db_query('select timestamp from appointments where app=? and type=? and cast(timestamp as integer) < ? order by cast(timestamp as integer) DESC LIMIT 1',
				$app,$filter,$t);
		}
		else {
			$query = &subs::db_query('select timestamp from appointments where app=? and cast(timestamp as integer) < ? order by cast(timestamp as integer) DESC LIMIT 1',
				$app,$t);
		}
	}
	elsif ($type eq 'next') {
		if ($filter ne 'all') {
			$query = &subs::db_query('select timestamp from appointments where app=? and type=? and cast(timestamp as integer) > ? order by cast(timestamp as integer) ASC LIMIT 1',
				$app,$filter,$t2);
		}
		else {
			$query = &subs::db_query('select timestamp from appointments where app=? and cast(timestamp as integer) > ? order by cast(timestamp as integer) ASC LIMIT 1',
				$app,$t2);
		}
	}

	my $res = $query->hashes;

	unless (defined $res->[0] && defined $res->[0]->{'timestamp'}) {
		$query = &subs::db_query('select timestamp from appointments where app=? and cast(timestamp as integer) = ? order by cast(timestamp as integer) ASC LIMIT 1',
			$app,$timestamp);
		$res = $query->hashes;
	}

	$date = &subs::iso_local($res->[0]->{'timestamp'}) if defined $res->[0] && defined $res->[0]->{'timestamp'};

	$c->render(json => { date => $date, sent_timestamp => $timestamp, new_timestamp => (defined $res->[0] ? $res->[0]->{'timestamp'} : undef) });

}

# POST /manager/pay/setting
sub action_8094 {
	my $c = shift;
	my $name = $c->param('setting') || '';
	unless (pay_setting_allowed($name)) {
		return $c->render(json => { ok => 0, error => 'that setting is not part of Pay' });
	}
	my $value = $c->param('value');
	$value = '' unless defined $value;
	if ($name eq 'interac_currency') {
		$value = uc($value);
		$value = 'CAD' unless $value =~ /^[A-Z]{3}$/;
	}
	if ($name eq 'base_url' && length $value) {
		$value =~ s{/+$}{};
		unless ($value =~ m{^https?://}i) {
			return $c->render(json => { ok => 0, error => 'the public address must start with http:// or https://' });
		}
	}
	my $sealed = 0;
	if (grep { $_ eq $name } &subs::pay_secret_names()) {
		if (length $value) {
			my $s = eval { &subs::note_encrypter(&subs::suds_grabber(), $value) };
			return $c->render(json => { ok => 0, error => 'the vault is locked, so the value cannot be sealed' }) unless defined $s && length $s;
			$value = $s;
			$sealed = 1;
		}
	}
	&subs::setting_setter({
		app => 'pay', setting => $name, value => $value,
		device => 'all', timestamp => $c->param('timestamp'),
	});
	$c->render(json => { ok => 1, setting => $name, sealed => $sealed });
}

# POST /manager/pay/test
sub action_8127 {
	my $c = shift;
	$c->render(json => &subs::pay_test_provider($c->param('provider') || ''));
}

# POST /manager/pay/interac/scan
sub action_8131 {
	my $c = shift;
	$c->render(json => &subs::pay_interac_scan());
}

# POST /manager/pay/interac/record
sub action_8135 {
	my $c = shift;
	$c->render(json => &subs::pay_interac_record($c->param('id') || '', $c->param('uuid') || '', $c->session('name') || ''));
}

# POST /manager/pay/interac/ignore
sub action_8139 {
	my $c = shift;
	$c->render(json => &subs::pay_interac_ignore($c->param('id') || ''));
}

# POST /manager/pay/interac/token
sub action_8143 {
	my $c = shift;
	my $token = &subs::random_string_creator(40);
	my $sealed = eval { &subs::note_encrypter(&subs::suds_grabber(), $token) };
	unless (defined $sealed && length $sealed) {
		return $c->render(json => { ok => 0, error => 'the vault is locked, so the token cannot be sealed' });
	}
	&subs::setting_setter({
		app => 'pay', setting => 'interac_hook_token',
		value => $sealed, device => 'all',
	});
	$c->render(json => { ok => 1 });
}

# GET /manager/webauthn/list
sub action_8965 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless ($c->session('authentication') || '') eq 'approved';
	my $p = &webauthn_person($c);
	my @out = map {
		{
			id          => $_->{'id'},
			name        => $_->{'name'} || 'Passkey',
			person_uuid => $_->{'person_uuid'} || '',
			person_name => $_->{'person_name'} || '',
			created     => $_->{'created'} || 0,
			last_used   => $_->{'last_used'} || 0,
			mine        => ($p && ($_->{'person_uuid'} || '') eq $p->{'uuid'}) ? 1 : 0,
		}
	} @{ &webauthn::credentials() };
	$c->render(json => {
		ok          => 1,
		rp          => &webauthn::rp_id(),
		person      => ($p ? { uuid => $p->{'uuid'}, name => $p->{'name'} } : undef),
		credentials => \@out,
	});
}

# POST /manager/webauthn/register/begin
sub action_8987 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless ($c->session('authentication') || '') eq 'approved';
	return $c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 }) unless &security_action_open($c);
	my $p = &webauthn_person($c);
	return $c->render(json => { ok => 0, error => 'this device is not assigned to a person yet - assign it in Security -> People first' }) unless $p;
	my $rp = &webauthn::rp_id();
	return $c->render(json => { ok => 0, error => 'set the house domain first (Configure -> Plat -> DNS)' }) unless length $rp;
	my $challenge = &webauthn::challenge_put('register', { person_uuid => $p->{'uuid'} });
	my @exclude = map { { type => 'public-key', id => $_->{'id'}, transports => [ qw(usb nfc ble) ] } }
		grep { ($_->{'person_uuid'} || '') eq $p->{'uuid'} } @{ &webauthn::credentials() };
	$c->render(json => {
		ok => 1,
		publicKey => {
			rp => { name => 'JawnOS', id => $rp },
			user => { id => &webauthn::user_handle($p->{'uuid'}), name => $p->{'name'}, displayName => $p->{'name'} },
			challenge => $challenge,
			pubKeyCredParams => [ { type => 'public-key', alg => -7 }, { type => 'public-key', alg => -8 } ],
			timeout => 300000,
			attestation => 'none',
			authenticatorSelection => { authenticatorAttachment => 'cross-platform', residentKey => 'preferred', userVerification => 'preferred' },
			excludeCredentials => \@exclude,
		},
	});
}

# POST /manager/webauthn/register/finish
sub action_9012 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless ($c->session('authentication') || '') eq 'approved';
	return $c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 }) unless &security_action_open($c);
	my $p = &webauthn_person($c);
	return $c->render(json => { ok => 0, error => 'no person' }) unless $p;
	my $cd = $c->param('client_data') || '';
	my $jd = eval { decode_json(&webauthn::b64u_decode($cd)) } || {};
	my $challenge = $jd->{'challenge'} || '';
	my $payload = &webauthn::challenge_take('register', $challenge);
	return $c->render(json => { ok => 0, error => 'the challenge expired - try again' }) unless $payload && ($payload->{'person_uuid'} || '') eq $p->{'uuid'};
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
		person_uuid => $p->{'uuid'},
		person_name => $p->{'name'},
		name        => $name,
		sign_count  => $reg->{'sign_count'},
		aaguid      => $reg->{'aaguid'},
		transports  => $transports,
		created     => &subs::rightNow(),
		last_used   => 0,
	};
	&webauthn::credentials_store($list);
	$log->info('webauthn: registered a passkey for ' . $p->{'name'} . ' (' . $reg->{'id'} . ')');
	$c->render(json => { ok => 1, id => $reg->{'id'} });
}

# POST /manager/webauthn/remove
sub action_9050 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless ($c->session('authentication') || '') eq 'approved';
	return $c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 }) unless &security_action_open($c);
	my $p = &webauthn_person($c);
	my $id = $c->param('id') || '';
	return $c->render(json => { ok => 0, error => 'no person' }) unless $p;
	my $list = &webauthn::credentials();
	my ($cred) = grep { ($_->{'id'} || '') eq $id } @{$list};
	return $c->render(json => { ok => 0, error => 'no such passkey' }) unless $cred;
	return $c->render(json => { ok => 0, error => 'that passkey belongs to someone else' }) unless ($cred->{'person_uuid'} || '') eq $p->{'uuid'};
	@{$list} = grep { ($_->{'id'} || '') ne $id } @{$list};
	&webauthn::credentials_store($list);
	$log->info('webauthn: removed a passkey for ' . $p->{'name'});
	$c->render(json => { ok => 1 });
}

# ---- enrollment in a real browser ----------------------------------------
# The installed app lives on 127.0.0.1, which no authenticator accepts as an
# origin. This mints a five-minute, single-use link that a browser opens on the
# house name; the page makes the credential and the link is spent.
# POST /manager/webauthn/enroll_link
sub action_9070 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless ($c->session('authentication') || '') eq 'approved';
	my $p = &webauthn_person($c);
	return $c->render(json => { ok => 0, error => 'this device is not assigned to a person yet' }) unless $p;
	my $host = &subs::public_origin_host();
	return $c->render(json => { ok => 0, error => 'set the house domain and this machine\'s name first' }) unless length $host;
	my $token = &webauthn::enroll_new({
		person_uuid => $p->{'uuid'},
		name        => $p->{'name'},
		device_uuid => ($c->session('app_device') || $c->session('device_uuid') || ''),
	});
	my $base = &webauthn::house_link_base($c);
	$c->render(json => {
		ok      => 1,
		url     => $base . '/passkey?t=' . $token,
		expires => 300,
	});
}

# POST /manager/webauthn/login/begin
sub action_9172 {
	my $c = shift;
	my $rp = &webauthn::rp_id();
	my @keys = grep { !&webauthn::platform_transport_only($_->{'transports'}) } @{ &webauthn::credentials() };
	return $c->render(json => { ok => 0, error => 'no passkeys on this house' }) unless length $rp && scalar @keys;
	my $challenge = &webauthn::challenge_put('login', {});
	my @allow = map { { type => 'public-key', id => $_->{'id'}, transports => [ qw(usb nfc ble) ] } } @keys;
	$c->render(json => {
		ok => 1,
		publicKey => {
			challenge => $challenge,
			rpId => $rp,
			timeout => 300000,
			userVerification => 'preferred',
			allowCredentials => \@allow,
		},
	});
}

# POST /manager/webauthn/login/finish
sub action_9190 {
	my $c = shift;
	my $ip = $c->tx->remote_address || '?';
	my $fails = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'webauthn_fail', $ip . ':%', &subs::rightNow() - 300000)->hash->{'n'} || 0;
	return $c->render(json => { ok => 0, error => 'too many attempts - wait five minutes' }) if $fails >= 10;
	my $id = $c->param('id') || '';
	my $cred = &webauthn::credential_by_id($id);
	if (!$cred) { &subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'webauthn_fail', app => '__president', server_time => &subs::rightNow(), timestamp => &subs::rightNow() }); return $c->render(json => { ok => 0, error => 'no such passkey' }); }
	my $cd = $c->param('client_data') || '';
	my $jd = eval { decode_json(&webauthn::b64u_decode($cd)) } || {};
	my $challenge = $jd->{'challenge'} || '';
	my $payload = &webauthn::challenge_take('login', $challenge);
	return $c->render(json => { ok => 0, error => 'the challenge expired - try again' }) unless $payload;
	my ($res, $err) = &webauthn::verify_assertion($cred, $cd, $c->param('auth_data'), $c->param('signature'), $challenge, &webauthn::origin_of($c));
	if (!$res) {
		&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'webauthn_fail', app => '__president', server_time => &subs::rightNow(), timestamp => &subs::rightNow() });
		$log->info('webauthn: login refused for ' . $id . ' from ' . $ip . ': ' . $err);
		return $c->render(json => { ok => 0, error => $err });
	}
	my $list = &webauthn::credentials();
	foreach my $row ( @{$list} ) {
		next unless ($row->{'id'} || '') eq $id;
		$row->{'sign_count'} = $res->{'sign_count'};
		$row->{'last_used'} = &subs::rightNow();
	}
	&webauthn::credentials_store($list);
	my $p = &subs::db_select('people', undef, { uuid => $cred->{'person_uuid'}, status => 'active' })->hash;
	my $now = &subs::rightNow();
	my ($db, $database) = &subs::database_grabber();
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'login_warranty' }) || '-12h', $now);
	$c->session(authentication => 'approved');
	$c->session(webauthn => 1);
	$c->session(source => 'webauthn');
	$c->session(bootstrap => undef);
	$c->session(person_uuid => $cred->{'person_uuid'});
	$c->session(name => ($p ? $p->{'name'} : $cred->{'person_name'}));
	$c->session(privilege => ($p && $p->{'privilege'}) ? $p->{'privilege'} : 'guest');
	$c->session(warranty => $warranty);
	$c->session(server_time => $now);
	$c->session(string => &subs::random_string_creator());
	$c->session(database => $database) if $database;
	my $suds = eval { &subs::suds_grabber() };
	$c->session(suds_id => &subs::suds_id($suds)) if $suds;
	$c->session('app' => undef);
	$c->session('app_device' => undef);
	&subs::db_query('delete from cache where context = ? and uuid like ?', 'webauthn_fail', $ip . ':%');
	$log->info('webauthn: login for ' . ($p ? $p->{'name'} : $cred->{'person_name'} || '?') . ' from ' . $ip . ' clone=' . ($res->{'clone'} ? 1 : 0));
	$c->render(json => { ok => 1, redirect => '/manager', person => ($p ? $p->{'name'} : $cred->{'person_name'}), clone => ($res->{'clone'} ? 1 : 0) });
}

# Issue or renew from the panel. Local only and signatorial-gated: the run
# writes DNS records and restarts the tree when the certificate changes.
# POST /manager/tls/issue
sub action_9241 {
	my $c = shift;
	my $sig = $c->param('signatorial') || '';
	return $c->render(json => { ok => 0, error => 'not authorised' }) unless length $sig && $sig eq &subs::signatorial_designer();
	my $ip = $c->tx->remote_address || '';
	return $c->render(json => { ok => 0, error => 'local only' }) unless $ip eq '127.0.0.1' || $ip eq '::1' || $ip eq '::ffff:127.0.0.1';
	&tls::tls_status_write({ at => POSIX::strftime('%Y-%m-%d %H:%M', localtime), ok => 0, message => 'issuing' });
	&subs::subprocessor(sub {
		system($^X, 'scripts/tls_issue.pl', '--renew');
	}, { name => 'tls issue' });
	$c->render(json => { ok => 1 });
}

# GET /manager/tls/status
sub action_9253 {
	my $c = shift;
	$c->render(json => &tls::tls_status_read());
}

# A pinned key is required: a known signatorial is not secret, so a stranger
# could otherwise claim it and receive or replace the tree on first contact.
# GET /manager/rsync_pack
sub action_9711 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) { $c->rendered(403); return; }
	my $tar = &code_sync_tar(&subs::home('~/'));
	$c->res->headers->content_type('application/x-gtar');
	$c->render(data => $tar);
}

# POST /manager/rsync_unpack
sub action_9720 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) { $c->rendered(403); return; }
	my $body = $c->req->body;
	$body = $body->slurp if ref $body;
	my $limit = 256 * 1024 * 1024;
	unless (defined $body && length($body) && length($body) <= $limit) {
		$c->rendered(length($body // '') > $limit ? 413 : 400);
		return;
	}
	my $home = &subs::home('~/');
	my $tmp = &subs::home('~/.president/rsync_recv_' . &subs::random_string_creator(8) . '.tgz');
	write_file($tmp, $body);
	my $ok = &code_sync_unpack($tmp, $home);
	unlink $tmp;
	unless ($ok) { $c->rendered(400); return; }
	$c->render(text => 'unpacked ' . length($body));
}

# The peer half of the DB backup: serve an encrypted archive by path, so the
# backup can ride http instead of sshpass+rsync. Authorized by the caller's
# signatorial; only *.enc files are ever served.
# GET /manager/backup_serve
sub action_9743 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) { $c->rendered(403); return; }
	&subs::sync_pull_touch();
	my $path = &subs::home($c->param('file') || '');
	my @roots = grep { defined && length } (&subs::backups_dir(), &subs::home('~/.president'));
	my $within = grep { &subs::path_is_within($path, $_) } @roots;
	unless ($within && $path =~ /\.enc$/ && -f $path) { $c->rendered(404); return; }
	# A remote backup's archive is a one-shot temp under ~/.president, made for
	# this pull; delete it once the body is on the wire rather than leave it for
	# the next boot's ~/.president wipe. Durable backups live beside the database
	# and are never touched here.
	# A puller that has been through the async build fetches the archive in
	# ranges, so a dropped tunnel resumes at the byte it reached instead of
	# starting the whole snapshot again. Only the full (non-range) reply deletes
	# the one-shot temp; a ranged reply leaves it for the confirm or the boot
	# wipe.
	my $size = -s $path;
	$c->res->headers->accept_ranges('bytes');
	my $range = $c->req->headers->range || '';
	if ($range && $range =~ /^bytes=(\d*)-(\d*)$/) {
		my ($start, $end) = ($1, $2);
		$start = 0 if $start eq '';
		$end = $size - 1 if $end eq '';
		if ($start > $end || $start >= $size || $end >= $size) {
			$c->res->headers->content_range("bytes */$size");
			$c->rendered(416);
			return;
		}
		my $len = $end - $start + 1;
		my $buf = '';
		if (open my $fh, '<:raw', $path) {
			sysseek($fh, $start, 0);
			sysread($fh, $buf, $len);
			close $fh;
		}
		$c->res->headers->content_type('application/octet-stream');
		$c->res->headers->content_range("bytes $start-$end/$size");
		$c->res->headers->content_length(length $buf);
		$c->res->body($buf);
		$c->rendered(206);
		return;
	}
	if ($path =~ m{/\.president/}) {
		$c->on(finish => sub { unlink $path; });
	}
	$c->res->headers->content_type('application/octet-stream');
	$c->res->headers->content_length($size);
	$c->res->content->asset(Mojo::Asset::File->new(path => $path));
	$c->rendered(200);
}

# GET /manager/debrief
sub action_9001 {
	my $c = shift;
	# The debrief is this browser's own store - personal data. The gate and the
	# ticket are the same pair the old grabber checked.
	unless ($c->session('authentication') eq 'approved' && $c->session('ticket_uuid')) {
		$c->render(json => {});
		return;
	}
	$c->render(json => &subs::debrief_read($c->session('ticket_uuid')));
}

# POST /manager/debrief
sub action_9002 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('ticket_uuid')) {
		$c->render(json => { saved => 0 });
		return;
	}
	my $debrief = $c->param('debriefer');
	my $saved = &subs::debrief_store($c->session('ticket_uuid'), $debrief);
	# The citizen's audit copy is the old heartbeat's second write, kept here
	# so the save has one home.
	if ($saved && $c->session('privilege') eq 'citizen') {
		my $hostname = `hostname`;
		chomp $hostname;
		&subs::setting_setter({ app => '__DEBRIEFING__', setting => $hostname, value => $debrief });
	}
	$c->render(json => { saved => $saved ? 1 : 0 });
}


1;
