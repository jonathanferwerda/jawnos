package Manager;

# manager_store2: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/store/appointment_option_selector
sub action_6978 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');

	my $appt_uuid = $c->param('appt_uuid');
	my $server_time = &subs::rightNow();
	my $app = $c->param('app');
	my $option = &subs::db_select('option', undef, { uuid => $uuid, app => $app })->hashes->[0];
	my $manufacturer = $c->param('manufacturer');
	my $quantity = $c->param('quantity');
	my $unit = $c->param('unit');
	if ($quantity =~ /[a-zA-Z]/) {
		my $gunit = $quantity;
		$gunit =~ s/[^a-zA-Z]//gi;
		$unit = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};
		$quantity =~ s/[^0-9.]//gi;
	}


	my $select = $c->param('select');
	my $all_options = eval { return decode_json $c->param('all_options') } || [];
	@{$all_options} = grep { $_->{'uuid'} ne $uuid } @{$all_options};
	my $appt = &subs::db_query('select * from appointments where uuid=? and app = ?', $appt_uuid, $app)->hashes->[0];

	my $options = eval { return decode_json $appt->{'options'} } || [];

	if (scalar @{$options} == 0 ) {
		foreach my $o ( @{$all_options} ) {
			push @{$options}, { uuid => $o->{'uuid'}, quantity => $o->{'quantity'}, timestamp => &subs::rightNow(), unit => $o->{'unit'}, name => $o->{'name'} };
		}
	}

	my @deletions = grep { $_->{'uuid'} eq $uuid } @{$options};
	foreach my $deleters ( @deletions ) {
		my $op = &subs::db_select('option', undef, { uuid => $deleters->{'uuid'}, app => $app })->hashes->[0];
		my $del = &subs::db_select('appointments', undef, { source_uuid => $appt->{'uuid'}, app => $op->{'name'} })->hashes->[0];
		&delete_app($del->{'app'},$del->{'uuid'},$del->{'server_time'},'appointment_option_Selector');
	}
	@{$options} = grep { $_->{'uuid'} ne $uuid } @{$options};

	if ($select eq 'on') {
		if ($quantity == 1 && $unit eq $app) {
			$quantity = $option->{'quantity'};
			$unit = $option->{'unit'};
			my $settings = &subs::settings_grabber({ app => $option->{'name'} });
			if (!$unit) {
				$unit = $settings->{'unit'};
			}
			if (!$quantity) {
				$quantity = $settings->{'quantity'};
			}
			if (!$unit) {
				$unit = $app;
			}
		}
		my $o = { uuid => $uuid, quantity => $quantity, timestamp => $timestamp, unit => $unit, name => $option->{'name'} };

		push @{$options}, $o;
		if ( $option->{'save_app'} eq 'on') {
			&subs::source_appt_writer($o, {
				app => $appt->{'app'},
				uuid => $appt->{'uuid'},
				type => $appt->{'type'},
				quantity => $quantity,
				unit => $unit,
				duration => $appt->{'duration'},
				timestamp => $appt->{'timestamp'},
				manufacturer => $manufacturer,
				project => $appt->{'project'}
			}, 'option');
		}
	}


	#if ( scalar @{$options} > 0 ) {
		my $joptions = encode_json $options;
		&subs::db_update('appointments', { options => $joptions, server_time => $server_time }, { app => $app, uuid => $appt_uuid });
	#}
	&Websocket::send($app, { console => &Websocket::console_command('appointmentDetailGrabber', $appt->{'app'}, $appt->{'uuid'})});
	$c->render(json => $options);

}

# POST /manager/store/crypto_panel
sub action_8267 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $cx = $c->param('cx_uuid');
	my $customer = ($cx && &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0]) || undef;
	unless ($customer && $customer->{'app'}) { return $c->render(json => { ok => 0, error => 'no customer' }); }
	my $inv = &subs::db_select('appointments', undef, { uuid => $uuid, app => $customer->{'app'} })->hashes->[0];
	unless ($inv && ($inv->{'type'} || '') eq 'invoice') { return $c->render(json => { ok => 0, error => 'no invoice' }); }
	my ($data, $balance) = &store_invoice_balance($inv);
	my $device_uuid = $c->session('device_uuid') || '';
	my $device = $device_uuid
		? &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]
		: undef;
	my $self_bio = ($device && $device->{'bio_pubkey'}) ? 1 : 0;
	my $bio_mode = $self_bio ? 'self' : (&house_bio_device($device_uuid) ? 'other' : 'none');
	# Every wallet on this invoice owns an address: the first time the payment
	# panel opens, an xpub wallet issues one; a wallet without one keeps its
	# single saved address.
	my $wallets = &subs::crypto_wallets_report();
	foreach my $w ( @{$wallets} ) {
		my $alloc = &subs::crypto_invoice_address({ app => $w->{'app'}, invoice => $uuid });
		if ($alloc && defined $alloc->{'address'} && length $alloc->{'address'}) {
			$w->{'address'} = $alloc->{'address'};
			$w->{'address_static'} = $alloc->{'static'} ? 1 : 0;
		}
		# the browser needs the address, never the key that derives the rest
		delete $w->{'xpub'};
	}
	my $html = $c->render_to_string(
		template => 'store/crypto_payment',
		invoice => $inv,
		invoice_data => $data,
		customer => $customer,
		wallets => $wallets,
		assets => &subs::crypto_enabled_assets(),
		balance => $balance,
		base => &subs::crypto_report_currency(),
		bio_mode => $bio_mode,
	);
	$c->render(json => { ok => 1, html => $html });
}

# POST /manager/store/crypto_payment
sub action_8308 {
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
	my $rate = &subs::crypto_rate($asset->{'code'});
	unless (defined $rate && $rate > 0) { return $c->render(json => { ok => 0, error => 'no ' . $asset->{'code'} . ' rate is loaded yet' }); }
	my $value = &subs::crypto_value($native, $asset->{'code'});
	unless (defined $value && $value > 0) { return $c->render(json => { ok => 0, error => 'the amount could not be valued' }); }
	my $account = &subs::unformat_name($c->param('account') || '');
	unless (&subs::crypto_account_asset($account) eq $asset->{'code'}) {
		return $c->render(json => { ok => 0, error => 'that account does not hold ' . $asset->{'code'} });
	}
	my $address = $c->param('address') || '';
	# The invoice owns the address, not the browser: a client cannot name a
	# different one. The submitted value is only a fallback for a wallet that
	# has no allocation at all (no xpub and no saved address).
	my $alloc = &subs::crypto_invoice_address({ app => $account, invoice => $uuid });
	$address = $alloc->{'address'} if $alloc && defined $alloc->{'address'} && length $alloc->{'address'};
	my $txid = $c->param('txid') || '';
	$txid =~ s/^\s+|\s+$//g;
	my $proof_code = $c->param('proof') || '';
	# A device with no fingerprint asks another device in the house. Its approval
	# is bound to this exact payment by the digest, so it cannot be moved to a
	# different amount or invoice.
	my $digest = &crypto_payment_digest($uuid, $cx, $asset->{'code'}, $native, $account, $txid, $proof_code);
	my $bio = &biometric_payment_confirmed($c);
	my $approval_id = $c->param('payment_request_id') || '';
	my $approved = 0;
	if (length $approval_id && $approval_id =~ /^[A-Za-z0-9]{8,64}$/) {
		my $req = &crypto_payment_request_get($approval_id);
		$approved = 1 if $req && ($req->{'approved_by'} || '') ne '' && ($req->{'digest'} || '') eq $digest;
	}
	unless ($bio->{'ok'} || $approved) {
		return $c->render(json => {
			ok => 0,
			need_biometric => 1,
			self => $bio->{'self'} ? 1 : 0,
			need_other_device => $bio->{'other'} ? 1 : 0,
			error => $bio->{'other'} ? 'another device must approve this payment' : 'fingerprint confirmation is needed',
		});
	}
	my ($proof, $payer, $verified) = ('', undef, $txid ? 'manual' : 'claimed');
	if (length $proof_code) {
		my $record = &subs::payment_proof_parse($proof_code);
		unless ($record && &subs::payment_proof_verify($record)) {
			return $c->render(json => { ok => 0, error => 'the payment proof did not verify' });
		}
		my $own = &subs::crest_record_read();
		my $proof_payee = ref $record->{'payee'} eq 'HASH' ? ($record->{'payee'}->{'uuid'} || '') : '';
		if (($own->{'uuid'} || '') ne '' && $proof_payee ne ($own->{'uuid'} || '')) {
			return $c->render(json => { ok => 0, error => 'the proof names another house as the payee' });
		}
		unless (uc($record->{'asset'} || '') eq $asset->{'code'}) {
			return $c->render(json => { ok => 0, error => 'the proof names a different coin' });
		}
		unless (&subs::payment_amount_matches($record->{'amount'}, $native)) {
			return $c->render(json => { ok => 0, error => 'the proof amount does not match' });
		}
		my $suds = &subs::session_suds($c);
		my $priv = $suds ? &subs::crest_key_read($suds) : undef;
		if (defined $priv && length $priv == 32) {
			$record = &subs::payment_proof_countersign($record, $priv);
			$verified = 'crest';
		}
		else {
			$verified = 'crest-unsigned';
		}
		$proof = encode_json($record);
		$payer = ref $record->{'payer'} eq 'HASH' ? $record->{'payer'} : undef;
	}
	# A proof proves the key signed; the roster says whether the house has met that
	# crest before. The seller sees the difference and decides whether to accept.
	my $payer_known = (ref $payer eq 'HASH' && length($payer->{'uuid'} || '') && &subs::crest_peer_find($payer->{'uuid'})) ? 1 : 0;
	my $ts = &timestamp_adjuster($c) || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $tx_uuid = &subs::random_string_creator(40);
	my $tx = {
		app => $app,
		account => $account,
		movement => 'income',
		type => 'transaction',
		timestamp => $ts,
		server_time => $server_time,
		uuid => $tx_uuid,
		amount => $value,
		total => $value,
		tax => 0,
		aux => 0,
		currency => &subs::crypto_report_currency(),
		item => &subs::unformat_name('Crypto ' . $asset->{'code'}),
		data => encode_json({
			crypto => {
				asset => $asset->{'code'},
				amount => $native,
				rate => $rate,
				rate_at => $server_time,
				txid => $txid,
				value => $value,
			},
		}),
	};
	&subs::db_insert('appointments', $tx);
	&warehouse_money_mirror($tx);
	my $payment = {
		account => $account,
		uuid => &subs::random_string_creator(12),
		appt_uuid => $tx_uuid,
		amount => $value,
		timestamp => $ts,
		server_time => $server_time,
		asset => $asset->{'code'},
		asset_amount => $native,
		rate => $rate,
		txid => $txid,
		address => $address,
		payer => $payer,
		proof => $proof,
		verified => $verified,
		payer_known => $payer_known,
	};
	push @{ $data->{'payments'} }, $payment;
	my $new_balance = $balance - $value;
	# A second send cannot be stopped on the chain, but it must not become a
	# negative balance: the invoice closes at zero and the excess is reported so
	# the seller can return it deliberately.
	my $overpaid = $new_balance < -0.005 ? -$new_balance : 0;
	$payment->{'overpaid'} = $overpaid if $overpaid > 0;
	$new_balance = 0 if $new_balance < 0;
	$new_balance = 0 if abs($new_balance) < 0.005;
	$data->{'numbers'}->{'balance'} = $new_balance;
	my $status = $new_balance <= 0 ? 'completed' : 'open';
	&subs::db_update('appointments', { data => encode_json($data), status => $status, server_time => $server_time }, { uuid => $uuid, app => $app });
	&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	$c->render(json => {
		ok => 1,
		payment => { %{$payment}, proof => undef },
		balance => $new_balance,
		status => $status,
		overpaid => $overpaid,
		verified => $verified,
		payer => $payer,
		payer_known => $payer_known,
	});
}

1;
