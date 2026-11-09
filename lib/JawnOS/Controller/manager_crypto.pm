package Manager;

# manager_crypto: route actions moved out of Manager.pl, one sub per route so a
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

# Type-ahead for the History app: a house has thousands of apps, so the list is
# searched on the server and only the matches travel.
# GET /manager/crypto/apps
sub action_8158 {
	my $c = shift;
	my $q = $c->param('q') // '';
	$q =~ s/^\s+|\s+$//g;
	return $c->render(json => { apps => [] }) unless length $q;
	$q =~ s/[%_\\]//g;
	my @words = grep { length } split /\s+/, $q;
	return $c->render(json => { apps => [] }) unless scalar @words;
	my $pat = '%' . join('%', @words) . '%';
	my $rows = &subs::db_query("select distinct app from settings where app like ? order by app limit 500", $pat)->hashes;
	my $extra = &subs::db_query("select distinct app from appointments where app like ? order by app limit 200", $pat)->hashes;
	push @{$rows}, @{$extra};
	my $ql = lc $q;
	my (%seen, @out);
	foreach my $r ( @{$rows} ) {
		my $app = $r->{'app'};
		next unless defined $app && length $app;
		next if $seen{$app}++;
		my $name = &subs::format_name($app);
		push @out, {
			app => $app,
			name => $name,
			rank => (index(lc($app), $ql) == 0 || index(lc($name), $ql) == 0) ? 0 : 1,
		};
	}
	@out = sort { $a->{'rank'} <=> $b->{'rank'} || lc($a->{'name'}) cmp lc($b->{'name'}) } @out;
	splice(@out, 25) if scalar @out > 25;
	$c->render(json => { apps => \@out });
}

# POST /manager/crypto/tracking_app
sub action_8187 {
	my $c = shift;
	my $value = $c->param('value') // '';
	$value =~ s/^\s+|\s+$//g;
	if (!length $value) {
		&subs::setting_deleter({ app => 'crypto', setting => 'tracking_app', device => 'all' });
		$c->render(json => { ok => 1, app => '', name => '' });
		return;
	}
	# An exact app key wins, then an exact formatted name; anything else is a new
	# name, normalised the way every other app name is.
	my $app = '';
	my $rows = &subs::db_query('select distinct app from settings where lower(app) = lower(?) limit 1', $value)->hashes;
	$app = $rows->[0]->{'app'} if $rows->[0];
	unless (length $app) {
		my $want = lc(&subs::format_name($value));
		my $all = &subs::db_query('select distinct app from settings order by app')->hashes;
		foreach my $r ( @{$all} ) {
			next unless lc(&subs::format_name($r->{'app'})) eq $want;
			$app = $r->{'app'};
			last;
		}
	}
	$app = lc(&subs::unformat_name($value)) unless length $app;
	&subs::setting_setter({ app => 'crypto', setting => 'tracking_app', value => $app, device => 'all' });
	if (&subs::crypto_tracking_on()) {
		eval { &subs::crypto_tracking_tick({ force => 1, create => 1 }) };
	}
	$c->render(json => { ok => 1, app => $app, name => &subs::format_name($app) });
}

# A device without a fingerprint asks the house: this stores what is being
# approved (by digest) and prompts every fingerprinted device. The first
# approval wins; the record route checks it before writing.
# POST /manager/crypto/payment_request
sub action_8469 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		return $c->render(json => { ok => 0, error => 'sign in first' });
	}
	my $uuid = $c->param('uuid');
	my $cx = $c->param('cx_uuid');
	my $customer = ($cx && &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0]) || undef;
	unless ($customer && $customer->{'app'}) { return $c->render(json => { ok => 0, error => 'no customer' }); }
	my $app = $customer->{'app'};
	my $inv = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
	unless ($inv && ($inv->{'type'} || '') eq 'invoice') { return $c->render(json => { ok => 0, error => 'no invoice' }); }
	my ($data, $balance) = &store_invoice_balance($inv);
	if ($balance <= 0) { return $c->render(json => { ok => 0, error => 'this invoice is already paid' }); }
	my $asset = &subs::crypto_asset(uc($c->param('asset') || ''));
	unless ($asset) { return $c->render(json => { ok => 0, error => 'choose a coin' }); }
	my $native = &subs::crypto_amount_number($c->param('amount'), $asset);
	unless (defined $native && $native > 0) { return $c->render(json => { ok => 0, error => 'enter the amount that was sent' }); }
	my $account = &subs::unformat_name($c->param('account') || '');
	# The approval is for this invoice's own address; make sure it exists.
	&subs::crypto_invoice_address({ app => $account, invoice => $uuid }) if length $account;
	my $txid = $c->param('txid') || '';
	$txid =~ s/^\s+|\s+$//g;
	my $proof = $c->param('proof') || '';
	my $digest = &crypto_payment_digest($uuid, $cx, $asset->{'code'}, $native, $account, $txid, $proof);
	my $now = &subs::rightNow();
	&subs::db_query("delete from cache where context = 'crypto_payment_request' and server_time < ?", $now - 900000);
	my $id = &subs::random_string_creator(24);
	my $summary = $native . ' ' . $asset->{'code'} . ' for invoice ' . ($data->{'id'} || '');
	&subs::db_insert('cache', {
		uuid => $id,
		context => 'crypto_payment_request',
		app => '__president',
		data => encode_json({
			at => $now, requester => $c->session('device_uuid') || '',
			digest => $digest, summary => $summary,
			asset => $asset->{'code'}, amount => $native,
			invoice => $data->{'id'} || '', uuid => $uuid, cx => $cx,
		}),
		server_time => $now,
		timestamp => $now,
		device => 'all',
	});
	my $devices = &subs::db_select('paired_devices', undef, { status => 'active' })->hashes;
	my @targets = map { $_->{'uuid'} } grep { $_->{'bio_pubkey'} && length $_->{'bio_pubkey'} } @{$devices};
	&Websocket::send('server', {
		crypto_payment_prompt => 1,
		request_id => $id,
		source_device => $c->session('device_uuid') || '',
		summary => $summary,
		amount => $native,
		asset => $asset->{'code'},
		invoice => $data->{'id'} || '',
		targets => \@targets,
		timestamp => $now,
	});
	$c->render(json => { ok => 1, id => $id, targets => scalar @targets });
}

# POST /manager/crypto/payment_approve
sub action_8527 {
	my $c = shift;
	my $id = $c->param('request_id') || '';
	return $c->render(json => { ok => 0, error => 'no request' }) unless $id =~ /^[A-Za-z0-9]{8,64}$/;
	my $device_uuid = $c->param('device_uuid') || $c->session('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]) || undef;
	return $c->render(json => { ok => 0, error => 'not paired' }) unless $device && $device->{'bio_pubkey'};
	my $nonce = $c->param('nonce') || '';
	my $signature = $c->param('signature') || '';
	return $c->render(json => { ok => 0, error => 'no challenge' }) unless length $nonce && length $signature;
	return $c->render(json => { ok => 0, error => 'no challenge' }) unless &biometric_nonce_take('pay', $device_uuid, $nonce, 600000);
	my $msg = join("\n", 'crypto-payment', $device_uuid, $id, $nonce);
	unless (&subs::ecdsa_verify($device->{'bio_pubkey'}, $msg, $signature)) {
		return $c->render(json => { ok => 0, error => 'not accepted' });
	}
	my $request = &crypto_payment_request_get($id);
	return $c->render(json => { ok => 0, error => 'no request' }) unless $request;
	return $c->render(json => { ok => 0, error => 'already approved' }) if ($request->{'approved_by'} || '') ne '';
	$request->{'approved_by'} = $device_uuid;
	$request->{'approved_name'} = $device->{'name'} || '';
	$request->{'approved_at'} = &subs::rightNow();
	&subs::db_update('cache', { data => encode_json($request), server_time => &subs::rightNow() }, { uuid => $id, context => 'crypto_payment_request' });
	&Websocket::send('server', { crypto_payment_approved => 1, request_id => $id, approved_by => $device->{'name'} || $device_uuid, timestamp => &subs::rightNow() });
	$c->render(json => { ok => 1 });
}

# GET /manager/crypto/payment_request
sub action_8552 {
	my $c = shift;
	my $request = &crypto_payment_request_get($c->param('id'));
	return $c->render(json => { ok => 0, error => 'no request' }) unless $request;
	my $expired = (&subs::rightNow() - ($request->{'at'} || 0)) > 300000 ? 1 : 0;
	$c->render(json => {
		ok => 1,
		approved => ($request->{'approved_by'} || '') ne '' ? 1 : 0,
		by => $request->{'approved_name'} || '',
		expired => $expired,
	});
}

# The payer's half of a payment proof: this house signs what it sent, naming the
# seller's crest (a UUID or a CREST1Z code). The seller's Store panel verifies
# and countersigns it. A txid is carried, not chain-checked.
# POST /manager/crypto/proof_build
sub action_8685 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		return $c->render(json => { ok => 0, error => 'sign in first' });
	}
	my $own = &subs::crest_record_read();
	my $suds = &subs::session_suds($c);
	my $priv = $suds ? &subs::crest_key_read($suds) : undef;
	unless (($own->{'uuid'} || '') ne '' && defined $priv && length $priv == 32) {
		return $c->render(json => { ok => 0, error => 'this house has no crest key to sign with — unlock the house key first' });
	}
	my $asset = &subs::crypto_asset(uc($c->param('asset') || ''));
	unless ($asset) { return $c->render(json => { ok => 0, error => 'choose a coin' }); }
	my $amount = &subs::crypto_amount_number($c->param('amount'), $asset);
	unless (defined $amount && $amount > 0) { return $c->render(json => { ok => 0, error => 'enter the amount that was sent' }); }
	my $address = $c->param('address') || '';
	my $txid = $c->param('txid') || '';
	$txid =~ s/^\s+|\s+$//g;
	my $ref = $c->param('ref') || '';
	$ref =~ s/^\s+|\s+$//g;
	my $memo = $c->param('memo') || '';
	my $payee_value = $c->param('payee') || '';
	$payee_value =~ s/^\s+|\s+$//g;
	my ($payee_uuid, $payee_pubkey, $payee_name) = ('', '', '');
	if ($payee_value =~ /^CREST1/i) {
		my $rec = &subs::crest_code_parse($payee_value);
		unless ($rec && &subs::crest_verify_record($rec)) {
			return $c->render(json => { ok => 0, error => 'the seller\'s crest code did not verify' });
		}
		$payee_uuid = $rec->{'uuid'} || '';
		$payee_pubkey = $rec->{'pubkey'} || '';
		$payee_name = $rec->{'name'} || '';
	}
	else {
		$payee_uuid = $payee_value;
		unless ($payee_uuid =~ /^[A-Za-z0-9_-]{8,64}$/) {
			return $c->render(json => { ok => 0, error => 'enter the seller\'s crest uuid (the seller\'s crypto panel shows it)' });
		}
		my $entry = &subs::crest_peer_find($payee_uuid);
		if ($entry && ref $entry->{'crest'} eq 'HASH') {
			$payee_pubkey = $entry->{'crest'}->{'pubkey'} || '';
			$payee_name = $entry->{'crest'}->{'name'} || '';
		}
	}
	my $record = {
		format => 'jawnos-payment',
		version => 1,
		payer => {
			uuid => $own->{'uuid'},
			pubkey => $own->{'pubkey'},
			name => $own->{'name'} || '',
			fingerprint => $own->{'fingerprint'} || '',
		},
		payee => { uuid => $payee_uuid, pubkey => $payee_pubkey, name => $payee_name },
		asset => $asset->{'code'},
		amount => $amount,
		address => $address,
		txid => $txid,
		ref => $ref,
		at => &subs::rightNow(),
		memo => $memo,
	};
	my $signed = &subs::payment_proof_build($record, $priv);
	unless ($signed) { return $c->render(json => { ok => 0, error => 'the proof could not be signed' }); }
	my $code = &subs::payment_proof_code($signed);
	unless ($code) { return $c->render(json => { ok => 0, error => 'the proof could not be packed' }); }
	$c->render(json => {
		ok => 1,
		code => $code,
		payer => $record->{'payer'},
		payee => $record->{'payee'},
		verified => &subs::payment_proof_verify($signed) ? 1 : 0,
	});
}

# GET /manager/crypto/qr
sub action_8759 {
	my $c = shift;
	my $text = $c->param('text') || '';
	return $c->rendered(400) unless length $text && length $text <= 500;
	my $png = &subs::crest_qr_png($text);
	unless (defined $png && length $png) { return $c->rendered(503); }
	$c->res->headers->content_type('image/png');
	$c->render(data => $png);
}

# The transaction form converts a native amount as the person types it; this
# hands the browser the same snapshot the server writes with.
# GET /manager/crypto/rates
sub action_8770 {
	my $c = shift;
	my $r = &subs::crypto_rates_read();
	my $base = &subs::crypto_report_currency();
	my $rates = $r->{'rates'} || {};
	my $to = $rates->{$base};
	my %out;
	foreach my $a ( @{ &subs::crypto_assets() } ) {
		my $from = $rates->{ $a->{'code'} };
		$out{ $a->{'code'} } = $from / $to if defined $from && defined $to && $to > 0;
	}
	$c->render(json => {
		enabled => &subs::crypto_enabled() ? 1 : 0,
		at => $r->{'at'} || 0,
		source => $r->{'source'} || '',
		base => $base,
		rates => \%out,
	});
}

1;
