package Manager;

# Manager helpers, part 8 of 37. Moved out of Manager.pl so a
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
use IO::Compress::Gzip qw(gzip $GzipError);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, @manager_core_files, %manager_app_scripts, %manager_app_entry, %manager_toggle_apps, $manager_bundle_cache, %manager_chunk_cache, %manager_gzip_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub store_printer($data) {
	my $type = $data->{'type'};
	my $cx_uuid = $data->{'cx_uuid'};
	my $uuid = $data->{'uuid'};
	my $visibility = $data->{'visibility'};
	# A walk-in sale has no customer uuid to look up: the caller names the app
	# directly, and "Customer" is the house's anonymous account. An unknown or
	# empty customer is still a paper that prints instead of a route that dies.
	my $customer_app = $data->{'customer_app'};
	my $c = &subs::controller_builder();
	my $customer_s;
	if (defined $customer_app && length $customer_app) {
		$customer_s = { app => $customer_app };
	}
	else {
		$customer_s = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx_uuid })->hashes->[0];
	}
	$customer_s = { app => 'Customer' } unless ($customer_s->{'app'} || '') =~ /\S/;
	my $cx_settings = &subs::settings_grabber({ app => $customer_s->{'app'} });
	my $print_date = 0;
	my $due = &subs::setting_grabber({ app => 'me', setting => 'payment_due_date' });
	my $due_date;
	my $cx = $cx_settings;
	$cx->{'app'} = $customer_s->{'app'};

	my $registers;
	if ( $uuid eq 'all' ) {
		$registers = &subs::db_select('appointments', undef, { type => $type, app => $cx->{'app'} })->hashes;
	}
	else {
		$registers = &subs::db_select('appointments', undef, { type => $type, app => $cx->{'app'}, uuid => $uuid })->hashes;
	}
	my (@i);
	my $totals = { price => 0, tax => 0, discount => 0, total => 0 };
	my $payments = [];
	foreach my $reg ( @{$registers} ) {
		$reg->{'data'} = eval { return decode_json $reg->{'data'} } || {};

		push @i, $reg->{'data'}->{'id'};
		foreach my $t ( qw/subtotal discount tax aux total balance/ ) {
			$totals->{$t} += $reg->{'data'}->{'numbers'}->{$t};
		}
		if ($reg->{'timestamp'} > $print_date) {
			$print_date = $reg->{'timestamp'};
			if ($due) {
				$due_date = &subs::ago_calc($due, $print_date);
			}
			else {
				$due_date = $print_date;
			}
		}
		if ($reg->{'data'}->{'payments'}) {
			push @{$payments}, @{$reg->{'data'}->{'payments'}};
		}
	}
	my $id = join '<br>', @i;

	my $address = $c->tx->local_address;
	my $device_domain = &subs::db_query('select domain from devices where domain is not null')->hashes->[0]->{'domain'};


	if ($device_domain) {
		$address = $device_domain;
	}
	elsif ($config->{'domain'}) {
		my @d = split '\.', $config->{'domain'};
		if (scalar @d > 2) {
			shift @d;
			$address = join '.', @d;
			my $ping = `timeout .5 ping -c 1 $address`;
			unless ($ping =~ /ttl/gi) {
				$address = $config->{'domain'};
			}
		}
		else {
			$address = $config->{'domain'};
		}
	}

	my $public_url = 'https://' . $address . ':3000/public_view/' . $type . '/' . $uuid . '/' . $cx_uuid;
	# the paper a letter carries is rendered by this house's own instance when
	# the config gives it a name here: the pdf is drawn where the code and the
	# theme are current, while the printed link keeps the public address
	my $pdf_url = $config->{'domain'} ? 'https://' . $config->{'domain'} . ':3000/public_view/' . $type . '/' . $uuid . '/' . $cx_uuid : $public_url;

	# One QR on the paper. For a single unpaid invoice with a Bitcoin wallet it
	# is the payment request (BIP21, exact amount) rather than the document link;
	# every other document keeps the link it had. Reading only: the public view
	# renders this too, and a GET must not allocate an address.
	my $pay;
	if (($type || '') eq 'invoice' && $uuid ne 'all' && scalar @{$registers} == 1) {
		my $balance = $registers->[0]->{'data'}->{'numbers'}->{'balance'} // 0;
		if ($balance > 0) {
			my $wallet = &subs::crypto_invoice_wallet('BTC');
			if ($wallet && ($wallet->{'asset'} || '') eq 'BTC') {
				my $alloc = &subs::crypto_invoice_address_read($wallet->{'app'}, $uuid);
				my $addr = ($alloc && defined $alloc->{'address'}) ? $alloc->{'address'} : '';
				$addr = $wallet->{'address'} || '' unless length $addr;
				my $rate = &subs::crypto_rate('BTC');
				if (length $addr && defined $rate && $rate > 0) {
					my $native = sprintf('%.8f', $balance / $rate);
					$pay = {
						address => $addr,
						asset => 'BTC',
						amount => &subs::crypto_amount_format($native, 'BTC'),
						uri => &subs::crypto_bip21_uri($addr, $native),
					};
				}
			}
		}
	}
	my $qr = $pay ? $pay->{'uri'} : $public_url;
	# A till receipt is handed over, not scanned back to a public invoice page.
	my $qr_img = $customer_app ? '' : &subs::crest_qr_png($qr);
	$qr_img = '' unless defined $qr_img && length $qr_img;
	$qr_img = 'data:image/png;base64,' . encode_base64($qr_img) if length $qr_img;

	# The public invoice page also offers the online ways to settle it. The
	# printable sheet and the emailed attachment do not carry buttons, so only
	# the public route asks for them.
	my $pay_links;
	if ($data->{'public'} && ($type || '') eq 'invoice' && $uuid ne 'all' && scalar @{$registers} == 1) {
		$pay_links = &subs::pay_options_for(
			$c, $registers->[0], $registers->[0]->{'data'},
			$registers->[0]->{'data'}->{'numbers'}->{'balance'}, $cx_uuid
		);
	}

	my $returner = {
		template => '/store/printer/header',
		registers => $registers,
		type => $type,
		visibility => $visibility,
		uuid => $uuid,
		cx => $cx_settings,
		qr_code => $public_url,
		pdf_url => $pdf_url,
		qr_img => $qr_img,
		pay_note => $pay ? $pay->{'amount'} : '',
		pay_address => $pay ? $pay->{'address'} : '',
		pay_links => $pay_links,
		id => $id,
		totals => $totals,
		payments => $payments,
		print_date =>	localtime( $print_date / 1000 )->strftime('%b %d %Y'),
		due_date => localtime( &subs::ago_calc($due, $print_date) / 1000 )->strftime('%b %d %Y')
	};


	return $returner;

}

sub editor_maker($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $uuid = $c->param('article_uuid') || '';
	my $scope = $c->param('scope');
	my $timestamp = $c->param('timestamp');
	# A fresh profile has no scope yet, and the old client sent a self-assigned
	# timestamp; either one used to die in time_span and leave a silent 500.
	$scope = 'day' unless defined $scope && length $scope;
	$timestamp = &subs::rightNow() unless defined $timestamp && $timestamp =~ /^\d+$/;
	my $t = eval { &subs::time_span($scope, $timestamp) } || 0;
	my $t1 = ($timestamp - $t);
	my $t2 = ($t1 + $timestamp + $t1);
	my $articulation = &subs::db_query('select * from magazine order by timestamp DESC');# where timestamp >= ? and timestamp <= ?', $t, $t2);
	# fetched before the next database call: the kept handle finishes an unfetched
	# statement, and $articles would come back empty
	my $articles = $articulation->hashes;
	my $mag_cat = &subs::db_query('select distinct(app) from settings where (setting=? or setting=?) and value=?','pos','mab','category');
	my $magazine_categories = $mag_cat->hashes;
	# The picker can be empty (a new file) or the stored uuid can be gone. Give
	# the page one complete row so its colour/status/time controls never read
	# from an undefined array slot.
	my ($current) = grep { ($_->{'uuid'} // '') eq $uuid } @{$articles};
	$current ||= {
		uuid => $uuid, title => '', content => '', category => 'promo',
		status => 'draft', timestamp => $timestamp, warranty => 0,
		text_colour => '#000000', background_colour => '#ffffff'
	};
	# Stored content is markup, not text: it is cleaned here as well as on the way
	# in, so a row synced from another machine (or written before the allowlist)
	# cannot carry a script into the editor or the homepage.
	$current->{'content'} = &subs::article_html_clean($current->{'content'});

	my $contents = $c->render_to_string(
		template => 'editor',
		articles => $articles,
		uuid => $uuid,
		current => $current,
		magazine_categories => $magazine_categories,
		window_maker => $c->param('window_maker')
	);
	return $contents;
}

# Where the built bundle is memoised. The in-process cache below only ever helps
# the worker that built it: production runs several prefork workers and recycles
# each after `accepts`, so a per-process memo meant every fresh worker shelled
# out to terser again -- several seconds on the ~1.3MB concatenation -- and a
# page load stalled whenever it landed on a cold one. Sharing the built bytes on
# disk (keyed by the source signature) means terser runs once per code change for
# the whole machine, and every other worker just reads the file.
sub manager_bundle_paths {
	my $dir = &subs::home('~/.president');
	unless (-d $dir) {
		eval { require File::Path; File::Path::make_path($dir); };
	}
	$dir = '/tmp' unless -d $dir;
	return ($dir . '/manager_bundle.js', $dir . '/manager_bundle.sig');
}

# A lazy app chunk is built from the same entries and parts as the core bundle
# and memoised the same way; the key is the digest of the file list so two apps
# that share the synth do not fight over one cache file.
sub manager_chunk_paths {
	my ($key) = @_;
	$key =~ s/[^A-Za-z0-9_.-]+/_/g;
	my $dir = &subs::home('~/.president');
	unless (-d $dir) {
		eval { require File::Path; File::Path::make_path($dir); };
	}
	$dir = '/tmp' unless -d $dir;
	return ($dir . '/manager_app_' . $key . '.js', $dir . '/manager_app_' . $key . '.sig');
}

# The browser asks for gzip on every request. The bundle is ~1.5 MB of JS before
# compression and about a quarter of that after, so one gzip per signature (memoised
# in the worker) is the cheapest large win on a cold page load. If the module is
# missing the plain body is served.
sub js_gzip_body {
	my ($body) = @_;
	return '' unless defined $body && length $body;
	my $out = '';
	return '' unless gzip \$body => \$out;
	return $out;
}

sub js_minifier_command {
	return $js_minifier if defined $js_minifier;
	my @cands;
	unshift @cands, $ENV{'JAWN_JS_MINIFIER'} if $ENV{'JAWN_JS_MINIFIER'};
	push @cands, 'terser';
	push @cands, glob(&subs::home('~/.local/share/zed/languages/eslint/*/vscode-eslint/node_modules/.bin/terser'));
	foreach my $c (@cands) {
		next unless defined $c && length $c;
		if ($c =~ m{/}) {
			next unless -x $c;
		}
		else {
			my $found = `command -v $c 2>/dev/null`;
			chomp $found;
			next unless length $found;
			$c = $found;
		}
		return $js_minifier = $c if `$c --version 2>/dev/null` =~ /terser/i;
	}
	return $js_minifier = '';
}

sub js_minify {
	my ($text) = @_;
	my $cmd = js_minifier_command();
	return $text unless $cmd;
	my $tmp = '/tmp/jawn_bundle_' . $$ . '.js';
	my $out;
	eval {
		write_file($tmp, $text);
		if (open(my $fh, '-|', $cmd, $tmp, '-c')) {
			local $/;
			$out = <$fh>;
			close $fh;
			$out = undef unless $? == 0;
		}
		unlink $tmp;
	};
	unlink $tmp;
	return (defined $out && length $out > 1024) ? $out : $text;
}

sub password_maker($c) {
	my $sacred = $c->param('numerics');
	my @uploads = @{$c->req->uploads};
	my @numerics = split '', $sacred;
	my ($secret,$ass);
	my $count = scalar @numerics;
	if (scalar @uploads > 0) {
		foreach my $u ( @uploads ) {
			my $size = $u->size;
			if ($size > 10000000) {
				&subs::say_it('way too big of a file!');
				$c->rendered;
				return 'noway';
			}
		  $ass = $u->asset->slurp;
			$ass = encode_base64($ass, "");
			$ass =~ s/\\\n//gi;
			my @asset = split '', $ass;
			my $mid = scalar @asset / 2;
			my $low_mid = (scalar @asset * .3333);
			my $up_mid = (scalar @asset * .6666);
			my $keys = [];
			for (my $i = 1; $i <= $count; $i++) {
				my $d = ($i / scalar @numerics);
				if ($d =~ /\./) {
					my @s = split /\./, $d;
					$d = $s[0];
				}
				foreach my $nm ( ( $low_mid, $mid, $up_mid ) ) {
					my $n = ($nm / $i);
					if ($n =~ /\./) {
						my @s = split /\./, $n;
						$n = $s[0];
					}
					push @{$keys}, $n + $i;
					$secret = $secret . $asset[$n + $i] . $asset[$n + $i - 5];
				}
				$secret = $secret . $numerics[$i - 1];
			}
		}
	}
	if ($ass eq '') {
		$secret = $sacred;
	}
	return $secret;
}

# The login body: the password and identity fields ride the POST body, and the
# digest is appended to the query the peer signature covers. Length-prefixing
# keeps the canonical form unambiguous even if a value contains & or =.
sub sesh_body_digest {
	my ($fields) = @_;
	require Digest::SHA;
	my $sha = Digest::SHA->new(256);
	for my $k (qw(numerics president backup remote_timestamp manager_file)) {
		my $v = $fields->{$k} // '';
		$v = "$v";
		utf8::encode($v);
		$sha->add(length($v) . ':' . $v);
	}
	return $sha->hexdigest;
}

# --- Network app ------------------------------------------------------------
# The Network window is a thin client over scripts/jawnos_network.pl. The helper
# owns the fixed Linux command set (iwctl, ip, tailscale, systemctl) and answers
# JSON, so no interface name, SSID or passphrase ever reaches a shell. The phone
# calls its own window.JawnNetwork bridge in the browser and never comes here.
sub network_helper {
	my ($arguments, $stdin) = @_;
	return fixed_helper_answer('scripts/jawnos_network.pl', $arguments, $stdin, 'network');
}

sub bluetooth_helper {
	my ($arguments, $stdin) = @_;
	return fixed_helper_answer('scripts/jawnos_bluetooth.pl', $arguments, $stdin, 'Bluetooth');
}

# Both Network helpers are the same shape: a fixed script, an argument list and
# one JSON answer. Keep the path check and the unreadable-answer fallback in one
# place so a new helper cannot drift from the one beside it.
sub fixed_helper_answer {
	my ($script, $arguments, $stdin, $label) = @_;
	return { ok => 0, error => 'The ' . $label . ' helper is missing.' } unless -e $script;
	my $run = eval { &subs::subprocessor_command(
		[ $^X, $script, @{$arguments || []} ],
		{ name => lc($label) . ' helper', stdin => $stdin, stdout => 'capture', stderr => 'inherit' }
	) };
	return { ok => 0, error => 'The ' . $label . ' helper could not start.' } unless ref $run eq 'HASH' && $run->{'pid'};
	my $json = $run->{'output'} // '';
	my $answer = eval { decode_json($json) };
	return $answer if ref $answer eq 'HASH';
	return { ok => 0, error => 'The ' . $label . ' helper did not return a readable answer.' };
}

sub pay_setting_allowed {
	my ($name) = @_;
	return 0 unless defined $name && length $name;
	my @allowed = qw(
		enabled base_url
		stripe_enabled stripe_secret stripe_webhook_secret stripe_account
		square_enabled square_mode square_access_token square_location_id
		square_webhook_key square_webhook_url square_account
		paypal_enabled paypal_mode paypal_client_id paypal_secret paypal_webhook_id
		paypal_brand paypal_account
		interac_enabled interac_email interac_name interac_account interac_watch
		interac_auto interac_currency interac_instructions interac_autodeposit
	);
	return (grep { $_ eq $name } @allowed) ? 1 : 0;
}

# ---- crypto payments on a Store invoice -------------------------------------
# The seller shows a payment request, the buyer sends the coin, and the seller
# records it here. A payer's PAY1Z proof is checked against their crest and
# countersigned with the house's; the txid is carried, not chain-checked. The
# money side is an ordinary income transaction on the wallet account, so every
# statement keeps working.
sub house_bio_device {
	my ($except) = @_;
	my $rows = &subs::db_select('paired_devices', undef, { status => 'active' })->hashes;
	foreach my $d ( @{$rows} ) {
		next unless $d->{'bio_pubkey'} && length $d->{'bio_pubkey'};
		next if $except && ($d->{'uuid'} || '') eq $except;
		return $d;
	}
	return undef;
}

sub crypto_payment_digest {
	my ($uuid, $cx, $asset, $amount, $account, $txid, $proof) = @_;
	return &subs::sha256_hex(join("\x1f",
		$uuid // '', $cx // '', uc($asset // ''), $amount // '',
		$account // '', $txid // '', &subs::sha256_hex($proof // '')));
}

sub crypto_payment_request_get {
	my ($id) = @_;
	return undef unless defined $id && $id =~ /^[A-Za-z0-9]{8,64}$/;
	my $row = &subs::db_select('cache', undef, { uuid => $id, context => 'crypto_payment_request' })->hashes->[0];
	return undef unless $row;
	my $d = eval { decode_json($row->{'data'} || '') } || {};
	$d->{'id'} = $id;
	$d->{'at'} = $row->{'server_time'} || 0;
	return $d;
}

sub store_invoice_balance {
	my ($inv) = @_;
	my $data = eval { decode_json($inv->{'data'} || '') } || {};
	$data->{'numbers'} = {} unless ref $data->{'numbers'} eq 'HASH';
	$data->{'payments'} = [] unless ref $data->{'payments'} eq 'ARRAY';
	my $paid = 0;
	foreach my $p ( @{ $data->{'payments'} } ) {
		$paid += $p->{'amount'} if defined $p->{'amount'} && $p->{'amount'} =~ /[0-9]/;
	}
	my $balance = defined $data->{'numbers'}->{'balance'}
		? $data->{'numbers'}->{'balance'}
		: (($data->{'numbers'}->{'total'} || 0) - $paid);
	return ($data, $balance + 0, $paid + 0);
}

# ---- passkeys (WebAuthn) ---------------------------------------------------
# Registration needs a signed-in session and a person; login is the one thing
# that must work before anyone is signed in, so those two routes are public in
# app_public_path. A passkey session is marked webauthn so the app gate admits
# it: a key held by the platform, bound to this house's origin, is a stronger
# door than a ticket and is exactly what the gate exists to protect.
sub webauthn_person($c) {
	my $uuid = $c->session('person_uuid') || '';
	if (length $uuid) {
		my $p = &subs::db_select('people', undef, { uuid => $uuid, status => 'active' })->hash;
		return $p if $p;
	}
	my $dev = $c->session('app_device') || $c->session('device_uuid') || '';
	if (length $dev) {
		my $p = &subs::person_for_device($dev);
		return $p if $p;
	}
	return undef;
}

sub me_setting_list() {
	my ($db,$database,$sql) = &subs::database_grabber();

	my @settings = qw/mugshot log_me my_name home_plate currency tax information budget_alarm computer_name unit activity_timeout login_warranty warranty room_count duration worth pos advertise_watching gallery_appts/;
	my $settings = {};

	foreach my $dt ( @gb::device_types ) {
		foreach my $s (@settings) {
			my $res = eval {return &subs::db_select('settings', ['value'], { app => 'me', setting => $s, device => $dt })->hash->{value} };
			$settings->{$dt}->{$s} = $res;
		}
	}
	return $settings;
}

sub store_setting_list() {
	my ($db,$database,$sql) = &subs::database_grabber();

	my @settings = qw/store_name slogan logo markup sales_tax address email phone tax_number doc_notes payment_due_date/;
	my $settings = {};

	foreach my $dt ( @gb::device_types ) {
		foreach my $s (@settings) {
			my $res = eval {return &subs::db_select('settings', ['value'], { app => 'me', setting => $s, device => $dt })->hash->{value} };
			$settings->{$dt}->{$s} = $res;
		}
	}
	return $settings;
}

# Where a mugshot is rendered from. Older installs still hold a data URI in
# me.mugshot; those are returned as-is. A name is served by the public /mugshot
# route, which is where the image file actually lives (sealed, under
# photo_location/me). Returns undef when nothing is set.
sub mugshot_source($dev) {
	$dev = &subs::device_setter() unless defined $dev && length $dev;
	my $name = &subs::setting_grabber({ app => 'me', setting => 'mugshot', device => $dev });
	return undef unless defined $name && length $name;
	return $name if $name =~ /^data:/;
	return '/mugshot?device=' . Mojo::Util::url_escape($dev) . '&timestamp=' . &subs::rightNow();
}

# Code sync is a peer-key route, not a session route: a peer's cookie lapses,
# and a gated reply silently stalls a sync. Both routes require a pinned key
# (no trust-on-first-contact for a tree that can carry secrets) and are
# restricted to the jawnos folder. The exclusion list is the gitignored/secret
# side of the tree: .shots (the ticket and DB copies), the database, voices,
# releases, personal pictures, generated build caches and the agent notes.
sub code_sync_excludes {
	return join ' ', map { "--exclude='$_'" } (
		'jawnos/.git',
		'jawnos/config.json',
		'jawnos/database',
		'jawnos/public/images/jonathans',
		'jawnos/.shots',
		'jawnos/AGENTS.md',
		'jawnos/docs/AGENTS-notes.md',
		'jawnos/releases',
		'jawnos/voices',
		'jawnos/signatorials',
		'jawnos/.pio',
		'jawnos/jp/alarmclock/.pio',
		'jawnos/jt/.pio',
		'jawnos/jw/.pio',
		'jawnos/jt/build',
		'jawnos/jw/build',
		'*.pem',
		'*.key',
		'*.log',
	);
}

sub code_sync_tar {
	my $home = shift;
	my $excludes = &code_sync_excludes();
	return `tar czf - -C "$home" $excludes jawnos 2>/dev/null`;
}

# Extract only a tarball whose every member is under jawnos/; this keeps a
# compromised or mistaken peer from writing .ssh, .president or anything else
# in the home directory.
sub code_sync_unpack {
	my ($tmp, $home) = @_;
	my @members = `tar tzf "$tmp" 2>/dev/null`;
	return 0 unless @members;
	# A link member can point out of jawnos/ and a later member then writes
	# through it. Only a regular file or a folder may appear in the pack.
	my @types = `tar tvzf "$tmp" 2>/dev/null`;
	return 0 unless @types;
	foreach my $line (@types) {
		next if $line =~ /^\s/;   # the wrapped tail of a very long name
		return 0 unless $line =~ /^[-d]/;
	}
	foreach my $m (@members) {
		chomp $m;
		next if $m eq '' || $m eq '.' || $m eq './';
		$m =~ s{^\./}{};
		return 0 unless $m =~ m{^jawnos/} && $m !~ m{(^|/)\.\.(/|$)} && $m !~ m{^/};
	}
	my $rc = system('tar', 'xzf', $tmp, '-C', $home, '--no-same-owner', '--no-same-permissions');
	return 0 unless $rc == 0;
	# The pack excludes .git, so a synced checkout is dirty against its old HEAD
	# and its watcher would refuse to move. Reset it when the synced tree is a
	# shipped commit, or commit it locally when it is peer-only work.
	my ($norm, $nout) = &subs::git_checkout_normalize({ repo => "$home/jawnos", label => 'code sync',
		branch => &subs::sync_update_branch_get() });
	if ($subs::logfile && ($norm eq 'reset' || $norm eq 'committed')) {
		open(my $fh, '>>', $subs::logfile);
		print $fh &subs::rightNow() . " code sync: checkout $norm\n";
		close $fh;
	}
	return 1;
}

sub app_release_sha {
	my $path = shift;
	my @st = stat $path;
	return '' unless @st;
	my $key = "$path:$st[7]:$st[9]";
	require Digest::SHA;
	unless (exists $app_release_sha{$key}) {
		my $data = eval { read_file($path) };
		$app_release_sha{$key} = defined $data ? Digest::SHA::sha256_hex($data) : '';
	}
	return $app_release_sha{$key};
}

# The Windows self-updater answers the local Configure panel and, like the
# app-release rail, a verified peer. A named signatorial is not a credential: a
# peer request must carry the machine's signature and be at least a member. An
# approved session is the browser that rendered the panel; it has no key to sign
# with. Shared by the GET and POST routes so the two cannot drift.
sub windows_update_gate {
	my ($c) = @_;
	return 1 if (($c->session('authentication') || '') eq 'approved');
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	return ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'member')) ? 1 : 0;
}

sub app_release_lister {
	my $dir = &subs::releases_dir();
	my @out;
	opendir(my $dh, $dir) or return \@out;
	foreach my $f ( sort readdir($dh) ) {
		# One product now: the retired API app's APK is neither staged nor served.
		next unless my ($vc, $vn) = $f =~ /^jawnos-app-(\d+)-(.+)\.apk$/;
		my $path = "$dir/$f";
		push @out, {
			product     => 'app',
			versionCode => $vc + 0,
			versionName => $vn,
			filename    => $f,
			size        => (-s $path) + 0,
			sha256      => &app_release_sha($path),
		};
	}
	closedir $dh;
	return \@out;
}

# The voice models this machine can serve - the *.onnx files and their json under
# voices/. Only the models are shared: the piper binary is per-arch and stays
# local (say_piper_binary), so it is not listed here.
sub voice_lister {
	my $dir = &subs::voices_dir();
	my @out;
	opendir(my $dh, $dir) or return \@out;
	foreach my $f ( sort readdir($dh) ) {
		next unless $f =~ /^[A-Za-z0-9_.-]+\.onnx(\.json)?$/;
		my $path = "$dir/$f";
		next unless -f $path;
		push @out, {
			filename => $f,
			size     => (-s $path) + 0,
			sha256   => &app_release_sha($path),
		};
	}
	closedir $dh;
	return \@out;
}

# One encrypted batch of a table's rows: the wire unit of the v3 sync rail. The
# cursor is the last rowid the caller already has, so a dropped tunnel costs the
# batch, not the pull; the total is sent with the first batch for progress.
sub sync_rows_batch {
	my ($remote, $signatorial, $secret, $table, $cut, $after, $range) = @_;
	my $url = $remote->{'manager'} . '/manager/sync_rows?signatorial=' . $signatorial
		. '&table=' . Mojo::Util::url_escape($table)
		. '&limit=500&seal=js1';
	if (ref $range eq 'HASH' && defined $range->{'from'} && defined $range->{'to'}) {
		$url .= '&from=' . int($range->{'from'}) . '&to=' . int($range->{'to'});
	}
	else {
		$url .= '&cut=' . int($cut);
	}
	$url .= '&after=' . Mojo::Util::url_escape($after) if defined $after && $after ne '';
	my $res;
	# A batch is a small request a live peer answers in well under a second. A
	# dead route (an offline tailnet node, a peer that left the network) used to
	# sit here for 60s an attempt, three attempts long, before the pull reported
	# failure; bound it so the caller can fall back promptly.
	for my $attempt (1 .. 3) {
		$res = eval { $remote->{'ua'}->connect_timeout(3)->inactivity_timeout(10)->request_timeout(15)->get($url)->result };
		last if $res && $res->is_success;
		# A 4xx is the peer's answer (auth, an unknown table); retrying it only
		# delays the fallback. A dropped link or a 5xx is worth another try.
		last if $res && $res->code < 500;
		sleep 1 if $attempt < 3;
	}
	return (undef, 'the peer did not answer') unless $res;
	return (undef, 'HTTP ' . $res->code) unless $res->is_success;
	my $type = $res->headers->content_type || '';
	if ($type !~ m{octet-stream}) {
		# An unsealed reply is the producer refusing the request (auth, an unknown
		# table, or a local failure). A table this side knows and the peer does not
		# is a schema-skew skip, not a failed pull.
		my $err = eval { decode_json($res->body) } || {};
		my $why = $err->{'error'} || 'the peer refused the batch';
		return (undef, $why, ($why eq 'unknown table' ? 1 : 0));
	}
	my $plain = eval { &subs::decrypter_strict($secret, $res->body) };
	return (undef, 'the batch would not decrypt') unless defined $plain && length $plain;
	my $batch = eval { Sereal::Decoder->new({ no_bless_objects => 1 })->decode($plain) };
	return (undef, 'the batch would not decode') unless ref $batch eq 'HASH';
	return (undef, $batch->{'error'} || 'the peer refused the batch') unless $batch->{'ok'};
	# The sealed response is what crossed the wire; record it so a v3 pull's size is
	# visible in `backups.size` and the job note, the way a snapshot's size was.
	$batch->{'wire_bytes'} = length($res->body // '');
	return ($batch, undef);
}

# One table's band map, over the same sealed peer rail. The map is a few integers
# per band, so it is one request, not a cursor. An older peer has no route: that
# is a plain failure and the caller falls back to the whole-table read.
sub sync_buckets_batch {
	my ($remote, $signatorial, $secret, $table, $band) = @_;
	my $url = $remote->{'manager'} . '/manager/sync_buckets?signatorial=' . $signatorial
		. '&table=' . Mojo::Util::url_escape($table)
		. '&band=' . int($band) . '&seal=js1';
	my $res;
	# Same bound as a row batch: the map is a few integers, so a live peer is
	# instant and a dead route must not stall the tick for minutes.
	for my $attempt (1 .. 3) {
		$res = eval { $remote->{'ua'}->connect_timeout(3)->inactivity_timeout(10)->request_timeout(15)->get($url)->result };
		last if $res && $res->is_success;
		last if $res && $res->code < 500;
		sleep 1 if $attempt < 3;
	}
	return (undef, 'the peer did not answer') unless $res;
	return (undef, 'HTTP ' . $res->code) unless $res->is_success;
	my $type = $res->headers->content_type || '';
	unless ($type =~ m{octet-stream}) {
		my $err = eval { decode_json($res->body) } || {};
		return (undef, $err->{'error'} || 'the peer refused the bucket map');
	}
	my $plain = eval { &subs::decrypter_strict($secret, $res->body) };
	return (undef, 'the bucket map would not decrypt') unless defined $plain && length $plain;
	my $map = eval { Sereal::Decoder->new({ no_bless_objects => 1 })->decode($plain) };
	return (undef, 'the bucket map would not decode') unless ref $map eq 'HASH';
	return (undef, $map->{'error'} || 'the peer refused the bucket map') unless $map->{'ok'};
	return ($map, undef);
}

1;
