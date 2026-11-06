package subs;

# Pay: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $config;
our %m;

# The address a provider redirects back to, and the address a webhook is sent
# to. The public side of the house lives on port 3000; a house with a public
# name can override the whole thing with pay.base_url.
sub pay_public_base {
	my ($c) = @_;
	my $custom = &pay_setting('base_url', '');
	if (length $custom) { $custom =~ s{/+$}{}; return $custom; }
	my $domain = '';
	my $row = eval { &db_query("select domain from devices where domain is not null and domain != '' limit 1")->hashes->[0] };
	$domain = $row->{'domain'} if $row && $row->{'domain'};
	$domain = $config->{'domain'} if !length $domain && $config && $config->{'domain'};
	my $port = ($config && $config->{'port'}) ? $config->{'port'} : 3000;
	if (length $domain) { return 'https://' . $domain . ':' . $port; }
	# The public invoice page is served on the house's public port, not the
	# manager's working port, so a return or webhook built here must use it.
	my $host = '';
	if ($c) { $host = eval { $c->req->url->host } || ''; }
	if (length $host) { return 'https://' . $host . ':' . $port; }
	return '';
}

sub pay_webhook_url {
	my ($c, $provider) = @_;
	my $base = &pay_public_base($c);
	return $base . '/pay/' . $provider . '/webhook';
}

sub pay_ua {
	require Mojo::UserAgent;
	return Mojo::UserAgent->new(connect_timeout => 8, inactivity_timeout => 25, request_timeout => 35);
}

# The invoice's own reference, printed on the paper and used to match an
# e-transfer's message. It is the human id, not the uuid.
sub pay_invoice_ref {
	my ($data) = @_;
	my $id = ref $data eq 'HASH' ? ($data->{'id'} || '') : '';
	$id =~ s/[^A-Za-z0-9._-]//g;
	return $id;
}

sub pay_invoice_balance {
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

# Find the invoice a public payment link names. The customer uuid scopes it, so
# one invoice uuid cannot be paid through another customer's page.
sub pay_invoice_lookup {
	my ($uuid, $cx) = @_;
	return () unless defined $uuid && length $uuid;
	my $customer = $cx ? &db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0] : undef;
	my $inv = ($customer && $customer->{'app'})
		? &db_select('appointments', undef, { uuid => $uuid, app => $customer->{'app'} })->hashes->[0]
		: &db_select('appointments', undef, { uuid => $uuid })->hashes->[0];
	return () unless $inv && ($inv->{'type'} || '') eq 'invoice';
	my ($data, $balance, $paid) = &pay_invoice_balance($inv);
	return ($inv, $customer, $data, $balance, $paid);
}

# A hosted checkout is remembered for an hour so a refresh reopens the same one
# instead of creating a second charge. The key carries the amount, so a partial
# payment creates its own session.
sub pay_session_save {
	my ($provider, $uuid, $data) = @_;
	return unless defined $provider && defined $uuid && ref $data eq 'HASH';
	my $minor = int((($data->{'amount'} || 0) * 100) + 0.5);
	my $key = 'pay_session:' . $provider . ':' . $uuid . ':' . $minor;
	&db_query('delete from cache where context = ? and uuid = ?', 'pay_session', $key);
	my $now = &rightNow();
	&db_insert('cache', {
		uuid => $key,
		app => 'pay_session',
		context => 'pay_session',
		timestamp => $now,
		server_time => $now,
		warranty => $now + 3600000,
		data => encode_json({ %{$data}, provider => $provider, invoice_uuid => $uuid, at => $now }),
	});
}

sub pay_session_find {
	my ($provider, $uuid, $amount) = @_;
	return undef unless defined $provider && defined $uuid && length $uuid;
	my $rows = &db_query('select data, server_time from cache where context = ? and uuid like ? order by server_time desc limit 5', 'pay_session', 'pay_session:' . $provider . ':' . $uuid . ':%')->hashes;
	my $want = defined $amount ? int(($amount * 100) + 0.5) : undef;
	foreach my $r ( @{$rows} ) {
		my $d = eval { decode_json($r->{'data'} || '') } || {};
		next if defined $want && defined $d->{'amount'} && int(($d->{'amount'} * 100) + 0.5) != $want;
		return $d;
	}
	return undef;
}

sub pay_session_forget {
	my ($provider, $uuid) = @_;
	return unless defined $provider && defined $uuid && length $uuid;
	&db_query('delete from cache where context = ? and uuid like ?', 'pay_session', 'pay_session:' . $provider . ':' . $uuid . ':%');
}

# The one place a payment is written to an invoice. It is safe to call twice:
# a provider reference already on the invoice is reported, not counted again.
sub pay_record_payment {
	my ($args) = @_;
	$args ||= {};
	my $uuid = $args->{'uuid'} || '';
	my $cx = $args->{'cx'} || '';
	return { ok => 0, error => 'no invoice was named' } unless length $uuid;
	my ($inv, $customer, $data, $balance) = &pay_invoice_lookup($uuid, $cx);
	return { ok => 0, error => 'the invoice could not be found' } unless $inv;

	my $provider = lc($args->{'provider'} || 'other');
	my $ref = $args->{'ref'} || '';
	if (length $ref) {
		foreach my $p ( @{ $data->{'payments'} } ) {
			next unless ($p->{'provider'} || '') eq $provider;
			if (($p->{'provider_ref'} || '') eq $ref) {
				return { ok => 1, duplicate => 1, balance => $balance, uuid => $uuid, cx => $cx };
			}
		}
	}
	# A repeat of a payment that is already on the invoice is answered above. A
	# different reference on a settled invoice is a real extra payment (a second
	# checkout, or an e-transfer that arrived late), so it is recorded and shown
	# as an overpayment rather than silently dropped; the balance stays at zero.

	my $amount = defined $args->{'amount'} ? "$args->{'amount'}" : '0';
	$amount =~ s/[^0-9.\-]//g;
	$amount = 0 + $amount;
	return { ok => 0, error => 'the payment amount could not be read' } unless $amount > 0;
	my $base = &pay_currency();
	my $currency = uc($args->{'currency'} || $base);
	my $value = $amount;
	if ($currency ne $base) {
		my $rate = &exchange_rate($currency, $base);
		return { ok => 0, error => 'no rate is loaded to convert ' . $currency . ' to ' . $base } unless defined $rate && $rate > 0;
		$value = $amount * $rate;
	}
	$value = sprintf('%.2f', $value);
	return { ok => 0, error => 'the payment is worth nothing' } unless $value > 0;

	my $account = $args->{'account'} || &pay_account_for($provider);
	my $ts = $args->{'at'} || &rightNow();
	my $server_time = &rightNow();
	my $tx_uuid = &random_string_creator(40);
	if (length $account) {
		my $tx = {
			app => $inv->{'app'},
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
			currency => $base,
			item => &unformat_name(($args->{'label'} || $provider) . ' payment'),
			data => encode_json({ pay => {
				provider => $provider,
				ref => $ref,
				value => $value,
				currency => $currency,
				paid => $amount,
			} }),
		};
		&db_insert('appointments', $tx);
		&warehouse_money_mirror($tx);
	}

	my $payment = {
		account => $account,
		uuid => &random_string_creator(12),
		appt_uuid => $tx_uuid,
		amount => $value,
		timestamp => $ts,
		server_time => $server_time,
		provider => $provider,
		provider_ref => $ref,
		currency => $currency,
		paid => $amount,
		note => ($args->{'note'} || ''),
	};
	$payment->{'payer'} = $args->{'payer'} if ref $args->{'payer'} eq 'HASH';
	push @{ $data->{'payments'} }, $payment;
	my $new_balance = $balance - $value;
	my $overpaid = $new_balance < -0.005 ? -$new_balance : 0;
	$payment->{'overpaid'} = $overpaid if $overpaid > 0;
	$new_balance = 0 if $new_balance < 0;
	$new_balance = 0 if abs($new_balance) < 0.005;
	$data->{'numbers'}->{'balance'} = $new_balance;
	my $status = $new_balance <= 0 ? 'completed' : 'open';
	&db_update('appointments', { data => encode_json($data), status => $status, server_time => $server_time }, { uuid => $uuid, app => $inv->{'app'} });
	&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $inv->{'app'}, $uuid)});
	&pay_session_forget($provider, $uuid);
	return {
		ok => 1,
		payment => $payment,
		balance => $new_balance,
		status => $status,
		overpaid => $overpaid,
		account => $account,
		uuid => $uuid,
		cx => $cx,
	};
}

# What the public invoice page offers. Only providers that can actually finish
# are listed; Interac has no redirect, so it carries the address and reference
# the customer needs instead of a button.
sub pay_options_for {
	my ($c, $inv, $data, $balance, $cx) = @_;
	return undef unless &pay_on && defined $balance && $balance > 0.005;
	my @methods;
	foreach my $p ( qw/stripe square paypal/ ) {
		next unless &pay_provider_ready($p);
		my $label = $p eq 'stripe' ? 'Pay by card' : $p eq 'square' ? 'Pay with Square' : 'PayPal';
		push @methods, {
			id => $p,
			label => $label,
			url => '/pay/' . $p . '/start?uuid=' . url_escape($inv->{'uuid'}) . '&cx=' . url_escape($cx || ''),
		};
	}
	my $interac;
	if (&pay_provider_ready('interac')) {
		# The invoice balance is in the house currency; an e-Transfer is made in
		# the currency the receiving account uses, so show the customer that.
		my $icur = &pay_interac_currency();
		my $base_cur = &pay_currency();
		my $irate = ($icur eq $base_cur) ? 1 : &exchange_rate($base_cur, $icur);
		my $iamount = (defined $irate && $irate > 0) ? ($balance * $irate) : $balance;
		$interac = {
			email => &pay_setting('interac_email', ''),
			name => &pay_setting('interac_name', ''),
			reference => &pay_invoice_ref($data),
			instructions => &pay_setting('interac_instructions', ''),
			autodeposit => (&pay_setting('interac_autodeposit', 'off') eq 'on' ? 1 : 0),
			amount => $iamount,
			currency => $icur,
		};
	}
	return undef unless scalar @methods || $interac;
	return {
		amount => $balance,
		currency => &pay_currency(),
		methods => \@methods,
		interac => $interac,
	};
}

# Minor units: most currencies have cents, but a few do not. Checkout APIs
# want an integer, and paying 100x too much is worse than a wrong-looking row.
sub pay_minor {
	my ($amount, $currency) = @_;
	my %zero = map { $_ => 1 } qw(BIF CLP DJF GNF JPY KMF KRW MGA PYG RWF UGX VND VUV XAF XOF XPF);
	return int($amount + 0.5) if $zero{uc($currency || '')};
	return int(($amount * 100) + 0.5);
}

sub pay_major {
	my ($minor, $currency) = @_;
	my %zero = map { $_ => 1 } qw(BIF CLP DJF GNF JPY KMF KRW MGA PYG RWF UGX VND VUV XAF XOF XPF);
	return 0 + ($minor || 0) if $zero{uc($currency || '')};
	return ($minor || 0) / 100;
}

# ---- Stripe ---------------------------------------------------------------
sub pay_stripe_start {
	my ($args) = @_;
	my $secret = &pay_secret_read('stripe_secret');
	return { ok => 0, error => 'Stripe is not set up' } unless length $secret;
	my $currency = lc($args->{'currency'} || &pay_currency());
	my $form = {
		mode => 'payment',
		'payment_method_types[0]' => 'card',
		'line_items[0][quantity]' => 1,
		'line_items[0][price_data][currency]' => $currency,
		'line_items[0][price_data][unit_amount]' => &pay_minor($args->{'amount'}, $currency),
		'line_items[0][price_data][product_data][name]' => $args->{'item'},
		'client_reference_id' => $args->{'uuid'},
		'success_url' => $args->{'return_url'},
		'cancel_url' => $args->{'cancel_url'},
		'metadata[invoice_uuid]' => $args->{'uuid'},
		'metadata[cx]' => ($args->{'cx'} || ''),
		'metadata[app]' => ($args->{'app'} || ''),
	};
	$form->{'line_items[0][price_data][product_data][description]'} = $args->{'description'} if length($args->{'description'} || '');
	$form->{'customer_email'} = $args->{'email'} if length($args->{'email'} || '');
	my $res = eval { &pay_ua()->post('https://api.stripe.com/v1/checkout/sessions' => { Authorization => 'Bearer ' . $secret } => form => $form)->result };
	my $json = ($res && $res->body) ? (eval { decode_json($res->body) } || {}) : {};
	if (!$res || !$res->is_success || !$json->{'url'}) {
		my $why = ref $json->{'error'} eq 'HASH' ? ($json->{'error'}->{'message'} || '') : '';
		$why = 'the provider did not answer' unless length $why;
		return { ok => 0, error => 'Stripe: ' . $why };
	}
	&pay_session_save('stripe', $args->{'uuid'}, {
		amount => $args->{'amount'}, currency => $args->{'currency'},
		session_id => $json->{'id'}, url => $json->{'url'},
	});
	return { ok => 1, url => $json->{'url'}, ref => $json->{'id'} };
}

sub pay_stripe_session_read {
	my ($id) = @_;
	return undef unless defined $id && $id =~ /^cs_[A-Za-z0-9_]+$/;
	my $secret = &pay_secret_read('stripe_secret');
	return undef unless length $secret;
	my $res = eval { &pay_ua()->get('https://api.stripe.com/v1/checkout/sessions/' . $id => { Authorization => 'Bearer ' . $secret })->result };
	return undef unless $res && $res->is_success;
	return eval { decode_json($res->body) };
}

sub pay_stripe_signature_ok {
	my ($body, $header) = @_;
	my $secret = &pay_secret_read('stripe_webhook_secret');
	return 0 unless length $secret && defined $body && defined $header;
	my ($t) = $header =~ /(?:^|,)\s*t=(\d+)/;
	my @v1 = $header =~ /(?:^|,)\s*v1=([0-9a-f]{64})/g;
	return 0 unless defined $t && scalar @v1;
	return 0 if abs(time() - $t) > 300;
	require Digest::SHA;
	my $expected = Digest::SHA::hmac_sha256_hex($t . '.' . $body, $secret);
	return scalar(grep { &secure_compare($_, $expected) } @v1) ? 1 : 0;
}

sub pay_stripe_webhook {
	my ($event) = @_;
	return { ok => 0, error => 'no event' } unless ref $event eq 'HASH';
	my $type = $event->{'type'} || '';
	return { ok => 1, ignored => $type } unless $type eq 'checkout.session.completed' || $type eq 'checkout.session.async_payment_succeeded';
	my $s = ref $event->{'data'} eq 'HASH' ? ($event->{'data'}->{'object'} || {}) : {};
	return { ok => 1, ignored => 'not paid' } unless ($s->{'payment_status'} || '') eq 'paid';
	my $meta = ref $s->{'metadata'} eq 'HASH' ? $s->{'metadata'} : {};
	return &pay_record_payment({
		uuid => ($meta->{'invoice_uuid'} || ''),
		cx => ($meta->{'cx'} || ''),
		provider => 'stripe',
		ref => ($s->{'id'} || ''),
		amount => &pay_major(($s->{'amount_total'} || 0), uc($s->{'currency'} || '')),
		currency => uc($s->{'currency'} || ''),
		note => 'Stripe (webhook)',
	});
}

# ---- Square ---------------------------------------------------------------
sub pay_square_base {
	return &pay_setting('square_mode', 'production') eq 'sandbox' ? 'https://connect.squareupsandbox.com' : 'https://connect.squareup.com';
}

sub pay_square_start {
	my ($args) = @_;
	my $token = &pay_secret_read('square_access_token');
	my $loc = &pay_setting('square_location_id', '');
	return { ok => 0, error => 'Square is not set up' } unless length $token && length $loc;
	my $body = {
		idempotency_key => $args->{'uuid'} . '-' . &pay_minor($args->{'amount'}, $args->{'currency'}) . '-' . time(),
		order => {
			location_id => $loc,
			reference_id => $args->{'uuid'},
			line_items => [{
				name => $args->{'item'},
				quantity => '1',
				base_price_money => {
					amount => &pay_minor($args->{'amount'}, $args->{'currency'}),
					currency => uc($args->{'currency'} || &pay_currency()),
				},
			}],
			metadata => {
				invoice_uuid => $args->{'uuid'},
				cx => ($args->{'cx'} || ''),
				app => ($args->{'app'} || ''),
			},
		},
		checkout_options => { redirect_url => $args->{'return_url'} },
	};
	$body->{'pre_populated_data'} = { buyer_email => $args->{'email'} } if length($args->{'email'} || '');
	my $res = eval { &pay_ua()->post(&pay_square_base() . '/v2/online-checkout/payment-links' => {
		Authorization => 'Bearer ' . $token,
		'Content-Type' => 'application/json',
	} => json => $body)->result };
	my $json = ($res && $res->body) ? (eval { decode_json($res->body) } || {}) : {};
	my $link = ref $json->{'payment_link'} eq 'HASH' ? $json->{'payment_link'} : {};
	if (!$res || !$res->is_success || !$link->{'url'}) {
		my $why = ref $json->{'errors'} eq 'ARRAY' && @{ $json->{'errors'} } ? ($json->{'errors'}->[0]->{'detail'} || $json->{'errors'}->[0]->{'code'} || '') : '';
		$why = 'the provider did not answer' unless length $why;
		return { ok => 0, error => 'Square: ' . $why };
	}
	&pay_session_save('square', $args->{'uuid'}, {
		amount => $args->{'amount'}, currency => $args->{'currency'},
		order_id => ($link->{'order_id'} || ''), link_id => ($link->{'id'} || ''), url => $link->{'url'},
	});
	return { ok => 1, url => $link->{'url'}, ref => ($link->{'order_id'} || $link->{'id'}) };
}

sub pay_square_order_read {
	my ($id) = @_;
	return undef unless defined $id && length $id;
	my $token = &pay_secret_read('square_access_token');
	return undef unless length $token;
	my $res = eval { &pay_ua()->get(&pay_square_base() . '/v2/orders/' . url_escape($id) => { Authorization => 'Bearer ' . $token })->result };
	return undef unless $res && $res->is_success;
	my $json = eval { decode_json($res->body) } || {};
	return ref $json->{'order'} eq 'HASH' ? $json->{'order'} : undef;
}

sub pay_square_signature_ok {
	my ($body, $signature, $url) = @_;
	my $key = &pay_secret_read('square_webhook_key');
	return 0 unless length $key && defined $body && defined $signature;
	$url = &pay_setting('square_webhook_url', '') unless length($url || '');
	return 0 unless length($url || '');
	require Digest::SHA;
	my $expected = encode_base64(Digest::SHA::hmac_sha256($url . $body, $key), '');
	return &secure_compare($signature, $expected) ? 1 : 0;
}

sub pay_square_webhook {
	my ($event) = @_;
	return { ok => 0, error => 'no event' } unless ref $event eq 'HASH';
	my $type = $event->{'type'} || '';
	return { ok => 1, ignored => $type } unless $type eq 'payment.updated' || $type eq 'payment.created';
	my $obj = ref $event->{'data'} eq 'HASH' ? ($event->{'data'}->{'object'} || {}) : {};
	my $p = ref $obj->{'payment'} eq 'HASH' ? $obj->{'payment'} : $obj;
	return { ok => 1, ignored => 'not completed' } unless uc($p->{'status'} || '') eq 'COMPLETED';
	my $order_id = $p->{'order_id'} || '';
	my $order = $order_id ? &pay_square_order_read($order_id) : undef;
	my $meta = ($order && ref $order->{'metadata'} eq 'HASH') ? $order->{'metadata'} : {};
	my $uuid = $meta->{'invoice_uuid'} || ($order ? ($order->{'reference_id'} || '') : '');
	my $cx = $meta->{'cx'} || '';
	my $amount = ref $p->{'amount_money'} eq 'HASH' ? &pay_major(($p->{'amount_money'}->{'amount'} || 0), ($p->{'amount_money'}->{'currency'} || '')) : 0;
	my $currency = ref $p->{'amount_money'} eq 'HASH' ? ($p->{'amount_money'}->{'currency'} || '') : '';
	if (!$amount && $order && ref $order->{'total_money'} eq 'HASH') {
		$amount = &pay_major(($order->{'total_money'}->{'amount'} || 0), ($order->{'total_money'}->{'currency'} || ''));
		$currency = $order->{'total_money'}->{'currency'} || $currency;
	}
	return { ok => 0, error => 'the payment names no invoice' } unless length $uuid;
	return &pay_record_payment({
		uuid => $uuid, cx => $cx, provider => 'square',
		ref => ($p->{'id'} || $order_id), amount => $amount, currency => $currency,
		note => 'Square (webhook)',
	});
}

# ---- PayPal ---------------------------------------------------------------
sub pay_paypal_base {
	return &pay_setting('paypal_mode', 'live') eq 'sandbox' ? 'https://api-m.sandbox.paypal.com' : 'https://api-m.paypal.com';
}

sub pay_paypal_token {
	my $id = &pay_setting('paypal_client_id', '');
	my $secret = &pay_secret_read('paypal_secret');
	return (undef, 'PayPal is not set up') unless length $id && length $secret;
	my $res = eval { &pay_ua()->post(&pay_paypal_base() . '/v1/oauth2/token' => {
		Authorization => 'Basic ' . encode_base64($id . ':' . $secret, ''),
	} => form => { grant_type => 'client_credentials' })->result };
	my $json = ($res && $res->body) ? (eval { decode_json($res->body) } || {}) : {};
	return (undef, 'PayPal did not answer') unless $res && $res->is_success && $json->{'access_token'};
	return ($json->{'access_token'}, undef);
}

sub pay_paypal_start {
	my ($args) = @_;
	my ($token, $err) = &pay_paypal_token();
	return { ok => 0, error => $err || 'PayPal is not set up' } unless $token;
	my $brand = &pay_setting('paypal_brand', '') || &setting_grabber({ app => 'me', setting => 'store_name' }) || 'JawnOS';
	my $body = {
		intent => 'CAPTURE',
		purchase_units => [{
			reference_id => $args->{'uuid'},
			custom_id => $args->{'uuid'} . '|' . ($args->{'cx'} || ''),
			description => $args->{'item'},
			amount => {
				currency_code => uc($args->{'currency'} || &pay_currency()),
				value => sprintf('%.2f', $args->{'amount'} || 0),
			},
		}],
		application_context => {
			brand_name => $brand,
			user_action => 'PAY_NOW',
			return_url => $args->{'return_url'},
			cancel_url => $args->{'cancel_url'},
		},
	};
	my $res = eval { &pay_ua()->post(&pay_paypal_base() . '/v2/checkout/orders' => {
		Authorization => 'Bearer ' . $token, 'Content-Type' => 'application/json',
	} => json => $body)->result };
	my $json = ($res && $res->body) ? (eval { decode_json($res->body) } || {}) : {};
	my ($approve) = grep { ($_->{'rel'} || '') eq 'approve' } @{ ref $json->{'links'} eq 'ARRAY' ? $json->{'links'} : [] };
	if (!$res || !$res->is_success || !$approve || !$approve->{'href'}) {
		my $why = ref $json->{'details'} eq 'ARRAY' && @{ $json->{'details'} } ? ($json->{'details'}->[0]->{'description'} || $json->{'details'}->[0]->{'issue'} || '') : ($json->{'message'} || '');
		$why = 'the provider did not answer' unless length $why;
		return { ok => 0, error => 'PayPal: ' . $why };
	}
	&pay_session_save('paypal', $args->{'uuid'}, {
		amount => $args->{'amount'}, currency => $args->{'currency'},
		order_id => ($json->{'id'} || ''), url => $approve->{'href'},
	});
	return { ok => 1, url => $approve->{'href'}, ref => ($json->{'id'} || '') };
}

sub pay_paypal_order_read {
	my ($id) = @_;
	return undef unless defined $id && $id =~ /^[A-Za-z0-9-]{6,}$/;
	my ($token, $err) = &pay_paypal_token();
	return undef unless $token;
	my $res = eval { &pay_ua()->get(&pay_paypal_base() . '/v2/checkout/orders/' . url_escape($id) => { Authorization => 'Bearer ' . $token })->result };
	return undef unless $res && $res->is_success;
	return eval { decode_json($res->body) };
}

sub pay_paypal_capture {
	my ($id) = @_;
	return { ok => 0, error => 'no order' } unless defined $id && length $id;
	my ($token, $err) = &pay_paypal_token();
	return { ok => 0, error => $err || 'PayPal is not set up' } unless $token;
	my $res = eval { &pay_ua()->post(&pay_paypal_base() . '/v2/checkout/orders/' . url_escape($id) . '/capture' => {
		Authorization => 'Bearer ' . $token, 'Content-Type' => 'application/json',
	} => json => {})->result };
	my $json = ($res && $res->body) ? (eval { decode_json($res->body) } || {}) : {};
	return { ok => ($res && $res->is_success) ? 1 : 0, data => $json, error => ($res && $res->is_success) ? undef : ($json->{'message'} || 'PayPal did not capture the order') };
}

sub pay_paypal_capture_record {
	my ($order, $note) = @_;
	return { ok => 0, error => 'no order' } unless ref $order eq 'HASH';
	my $unit = ref $order->{'purchase_units'} eq 'ARRAY' ? ($order->{'purchase_units'}->[0] || {}) : {};
	my $capture = ref $unit->{'payments'} eq 'HASH' && ref $unit->{'payments'}->{'captures'} eq 'ARRAY' ? ($unit->{'payments'}->{'captures'}->[0] || {}) : {};
	return { ok => 0, error => 'PayPal has not captured this order yet' } unless uc($capture->{'status'} || '') eq 'COMPLETED';
	my $uuid = $unit->{'reference_id'} || '';
	my $cx = '';
	if (!length $uuid && length($unit->{'custom_id'} || '')) {
		($uuid, $cx) = split /\|/, $unit->{'custom_id'}, 2;
	}
	my $amount = ref $capture->{'amount'} eq 'HASH' ? $capture->{'amount'}->{'value'} : ($unit->{'amount'}->{'value'} || 0);
	my $currency = ref $capture->{'amount'} eq 'HASH' ? $capture->{'amount'}->{'currency_code'} : ($unit->{'amount'}->{'currency_code'} || '');
	return { ok => 0, error => 'the payment names no invoice' } unless length($uuid || '');
	return &pay_record_payment({
		uuid => $uuid, cx => $cx, provider => 'paypal',
		ref => ($capture->{'id'} || ''), amount => $amount, currency => $currency,
		note => ($note || 'PayPal'),
	});
}

sub pay_paypal_webhook_verify {
	my ($event, $h) = @_;
	my $id = &pay_secret_read('paypal_webhook_id');
	return 0 unless length $id;
	my ($token, $err) = &pay_paypal_token();
	return 0 unless $token;
	my $body = {
		auth_algo => $h->{'paypal-auth-algo'} || '',
		cert_url => $h->{'paypal-cert-url'} || '',
		transmission_id => $h->{'paypal-transmission-id'} || '',
		transmission_sig => $h->{'paypal-transmission-sig'} || '',
		transmission_time => $h->{'paypal-transmission-time'} || '',
		webhook_id => $id,
		webhook_event => $event,
	};
	my $res = eval { &pay_ua()->post(&pay_paypal_base() . '/v1/notifications/verify-webhook-signature' => {
		Authorization => 'Bearer ' . $token, 'Content-Type' => 'application/json',
	} => json => $body)->result };
	return 0 unless $res && $res->is_success;
	my $json = eval { decode_json($res->body) } || {};
	return ($json->{'verification_status'} || '') eq 'SUCCESS' ? 1 : 0;
}

sub pay_paypal_webhook {
	my ($event, $verified) = @_;
	return { ok => 0, error => 'the webhook signature did not verify' } unless $verified;
	return { ok => 0, error => 'no event' } unless ref $event eq 'HASH';
	my $type = $event->{'event_type'} || '';
	my $res = ref $event->{'resource'} eq 'HASH' ? $event->{'resource'} : {};
	if ($type eq 'CHECKOUT.ORDER.APPROVED') {
		my $id = $res->{'id'} || '';
		my $cap = &pay_paypal_capture($id);
		if (!$cap->{'ok'}) {
			# A retry can arrive after the first capture; read the order back and
			# record what is already there rather than refusing the webhook.
			my $issue = ref $cap->{'data'} eq 'HASH' && ref $cap->{'data'}->{'details'} eq 'ARRAY' && @{ $cap->{'data'}->{'details'} }
				? ($cap->{'data'}->{'details'}->[0]->{'issue'} || '') : '';
			my $order = $issue eq 'ORDER_ALREADY_CAPTURED' ? &pay_paypal_order_read($id) : undef;
			return { ok => 0, error => $cap->{'error'} } unless $order;
			return &pay_paypal_capture_record($order, 'PayPal (webhook)');
		}
		return &pay_paypal_capture_record($cap->{'data'}, 'PayPal (webhook)');
	}
	if ($type eq 'PAYMENT.CAPTURE.COMPLETED') {
		my $order_id = ref $res->{'supplementary_data'} eq 'HASH' && ref $res->{'supplementary_data'}->{'related_ids'} eq 'HASH'
			? ($res->{'supplementary_data'}->{'related_ids'}->{'order_id'} || '') : '';
		my $order = length $order_id ? &pay_paypal_order_read($order_id) : undef;
		if ($order) { return &pay_paypal_capture_record($order, 'PayPal (webhook)'); }
		my ($uuid, $cx) = split /\|/, ($res->{'custom_id'} || ''), 2;
		return &pay_record_payment({
			uuid => $uuid, cx => ($cx || ''), provider => 'paypal',
			ref => ($res->{'id'} || ''),
			amount => (ref $res->{'amount'} eq 'HASH' ? $res->{'amount'}->{'value'} : 0),
			currency => (ref $res->{'amount'} eq 'HASH' ? $res->{'amount'}->{'currency_code'} : ''),
			note => 'PayPal (webhook)',
		});
	}
	return { ok => 1, ignored => $type };
}

# ---- starting and finishing a checkout ------------------------------------
# One entry point both the public page and a return use, so the invoice lookup
# and the readiness check cannot drift apart.
sub pay_start {
	my ($provider, $c, $uuid, $cx) = @_;
	$provider = lc($provider || '');
	return { ok => 0, error => 'that payment method is not available' } unless grep { $_ eq $provider } qw/stripe square paypal/;
	return { ok => 0, error => 'online payment is turned off' } unless &pay_provider_ready($provider);
	my ($inv, $customer, $data, $balance) = &pay_invoice_lookup($uuid, $cx);
	return { ok => 0, error => 'the invoice could not be found' } unless $inv;
	return { ok => 0, error => 'this invoice is already paid' } if $balance <= 0.005;
	my $base = &pay_public_base($c);
	my $ref = &pay_invoice_ref($data);
	# One opaque "cid" carries the invoice and customer through the provider's
	# redirect. Some providers append their own query to the return URL; the
	# invoice uuid is still recoverable from this value even then.
	my $cid = url_escape($uuid . '|' . ($cx || ''));
	my $return_url = $base . '/pay/' . $provider . '/return?cid=' . $cid;
	$return_url .= '&session_id={CHECKOUT_SESSION_ID}' if $provider eq 'stripe';
	my $cancel_url = $base . '/public_view/invoice/' . url_escape($uuid) . '/' . url_escape($cx || '');
	my $email = '';
	if ($customer && $customer->{'app'}) {
		my $es = &setting_grabber({ app => $customer->{'app'}, setting => 'email' });
		$email = $es || '';
	}
	my $store = &setting_grabber({ app => 'me', setting => 'store_name' }) || 'JawnOS';
	my $args = {
		uuid => $uuid, cx => $cx, app => $inv->{'app'},
		amount => $balance, currency => &pay_currency(),
		item => 'Invoice ' . ($ref || $uuid),
		description => 'Payment to ' . &format_name($store) . ' for invoice ' . ($ref || $uuid),
		email => $email, return_url => $return_url, cancel_url => $cancel_url,
	};
	if ($provider eq 'stripe') { return &pay_stripe_start($args); }
	if ($provider eq 'square') { return &pay_square_start($args); }
	if ($provider eq 'paypal') { return &pay_paypal_start($args); }
	return { ok => 0, error => 'that payment method is not available' };
}

1;
