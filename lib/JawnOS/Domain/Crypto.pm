package subs;

# Crypto: extracted from subroutines.pl (package subs). Loaded on
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

our %H;
# ---- crypto wallets and live exchange rates --------------------------------
# A wallet is an ordinary account app whose tender is crypto. JawnOS keeps the
# public address and the asset, never a key or a seed phrase: it can say what a
# wallet holds and what that is worth, but it cannot spend from it, and nothing
# here ever asks for a phrase that could.
#
# Rates are one cached snapshot, denominated in the house's reporting currency:
# rates{CODE} is how much of that currency one unit of CODE is worth. One
# Coinbase call returns every fiat code and every coin; open.er-api is the
# fiat-only fallback for a first boot. formula_calculator reads the same
# snapshot, so 'x USD to CAD' is live too instead of the hand-written constants
# in gb.pl.
our @crypto_asset_list;
our @crypto_fiat_table;
our $crypto_secp256k1_n;
our %crypto_xpub_version;
our $device;
our %m;

# Decode an account xpub (or ypub/zpub and their testnet forms). Returns the
# public key and chain code plus the script type the version bytes name.
sub crypto_xpub_decode {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	my $s = $text;
	$s =~ s/^\s+|\s+$//g;
	my $raw = &crypto_base58check_decode($s);
	return undef unless defined $raw && length($raw) == 78;
	my ($version, $depth, $fingerprint, $child, $chain, $pub) = unpack('N C a4 N a32 a33', $raw);
	my $v = $crypto_xpub_version{$version} or return undef;
	return undef unless length($pub) == 33
		&& (substr($pub, 0, 1) eq "\x02" || substr($pub, 0, 1) eq "\x03");
	return {
		version => $version, depth => $depth, fingerprint => unpack('H*', $fingerprint),
		child => $child, chain => $chain, pub => $pub,
		script => $v->{'script'}, net => $v->{'net'},
	};
}

sub crypto_xpub_valid {
	my ($text) = @_;
	return 0 if &crypto_xpub_is_private($text);
	return defined &crypto_xpub_decode($text) ? 1 : 0;
}

# One non-hardened public child. Returns undef when BIP32 says the child is
# invalid (IL = 0 or IL >= n), so the caller can try the next index.
sub crypto_xpub_child {
	my ($x, $index) = @_;
	return undef unless ref $x eq 'HASH' && defined $x->{'pub'} && defined $x->{'chain'};
	$index = 0 unless defined $index && $index =~ /^\d+$/;
	my $I = Digest::SHA::hmac_sha512($x->{'pub'} . pack('N', $index), $x->{'chain'});
	my $IL = substr($I, 0, 32);
	my $IR = substr($I, 32, 32);
	my $il = Math::BigInt->from_bytes($IL);
	return undef if $il->is_zero || $il->bcmp($crypto_secp256k1_n) >= 0;
	my ($gx, $gy) = &crypto_secp256k1_mul_g($IL);
	return undef unless defined $gx;
	my ($px, $py) = &crypto_secp256k1_pub_parse($x->{'pub'});
	return undef unless defined $px;
	my ($cx, $cy) = &crypto_secp256k1_add($px, $py, $gx, $gy);
	return undef unless defined $cx;
	return {
		pub => &crypto_secp256k1_compress($cx, $cy),
		chain => $IR,
		index => $index,
		depth => ($x->{'depth'} // 0) + 1,
	};
}

# The address at /0/index under an account xpub, encoded for the script type
# the key names. This is the external (receive) chain only; change addresses
# live at /1/index and are never issued here.
sub crypto_xpub_address {
	my ($xpub, $index) = @_;
	my $x = ref $xpub eq 'HASH' ? $xpub : &crypto_xpub_decode($xpub);
	return undef unless $x;
	$index = 0 unless defined $index && $index =~ /^\d+$/;
	my $ext = &crypto_xpub_child($x, 0);
	return undef unless $ext;
	my $child = &crypto_xpub_child($ext, $index);
	return undef unless $child;
	my $hash = &crypto_hash160($child->{'pub'});
	return undef unless defined $hash && length($hash) == 20;
	my $address;
	if ($x->{'script'} eq 'p2wpkh') {
		$address = &crypto_segwit_encode($x->{'net'} eq 'test' ? 'tb' : 'bc', 0, $hash);
	}
	elsif ($x->{'script'} eq 'p2sh-p2wpkh') {
		my $redeem = "\x00\x14" . $hash;
		$address = &crypto_base58check_encode(($x->{'net'} eq 'test' ? "\xC4" : "\x05") . &crypto_hash160($redeem));
	}
	else {
		$address = &crypto_base58check_encode(($x->{'net'} eq 'test' ? "\x6F" : "\x00") . $hash);
	}
	return undef unless defined $address && length $address;
	my $purpose = $x->{'script'} eq 'p2pkh' ? 44 : $x->{'script'} eq 'p2sh-p2wpkh' ? 49 : 84;
	my $coin = $x->{'net'} eq 'test' ? "1'" : "0'";
	return {
		address => $address,
		index => $index,
		path => "m/$purpose'/$coin/0'/0/$index",
		script => $x->{'script'},
		net => $x->{'net'},
	};
}

# A BIP21 payment request: the address and, when known, the exact amount. No
# label or message, so no ampersand ever reaches the QR encoder's argument.
sub crypto_bip21_uri {
	my ($address, $amount) = @_;
	return '' unless defined $address && length $address;
	my $n = &crypto_amount_number($amount, 'BTC');
	return 'bitcoin:' . $address . (defined $n && $n =~ /[1-9]/ ? '?amount=' . $n : '');
}

sub crypto_rates_read {
	my $raw = &setting_grabber({ app => 'crypto', setting => 'rates', device => 'all' });
	my $r = eval { decode_json($raw) };
	$r = {} unless ref $r eq 'HASH';
	$r->{'rates'} = {} unless ref $r->{'rates'} eq 'HASH';
	$r->{'at'} = 0 unless defined $r->{'at'} && $r->{'at'} =~ /^\d+$/;
	return $r;
}

sub crypto_rates_write {
	my ($rates, $source, $base) = @_;
	return 0 unless ref $rates eq 'HASH';
	# Rates are one house-wide snapshot. A row left on a single device by an
	# older build (or replayed by a peer) is stale and would double the payload;
	# the shared row is the only one read.
	&db_query("delete from settings where app = 'crypto' and setting = 'rates' and device != 'all'");
	my $payload = {
		at => &rightNow(),
		source => ($source || 'manual'),
		base => ($base || &crypto_report_currency()),
		rates => $rates,
	};
	&setting_setter({ app => 'crypto', setting => 'rates', value => encode_json($payload), device => 'all' });
	return $payload;
}

# reporting currency per one unit of $code
sub crypto_rate {
	my ($code, $base) = @_;
	$code = uc($code || '');
	return undef unless length $code;
	my $r = &crypto_rates_read();
	my $rates = $r->{'rates'};
	my $from = $rates->{$code};
	return undef unless defined $from && $from > 0;
	$base = uc($base || '');
	$base = &crypto_report_currency() unless length $base;
	my $to = $rates->{$base};
	return undef unless defined $to && $to > 0;
	return $from / $to;
}

sub crypto_rate_age {
	my $r = &crypto_rates_read();
	return undef unless $r->{'at'};
	return &rightNow() - $r->{'at'};
}

# A fiat pair, read from the same snapshot. The static formulas in gb.pl are the
# fallback only while no snapshot exists yet.
sub exchange_rate {
	my ($from, $to) = @_;
	$from = uc($from || '');
	$to = uc($to || '');
	return undef unless length $from && length $to;
	return 1 if $from eq $to;
	my $r = &crypto_rates_read();
	my $rates = $r->{'rates'};
	my ($f, $t) = ($rates->{$from}, $rates->{$to});
	return undef unless defined $f && defined $t && $f > 0 && $t > 0;
	return $f / $t;
}

sub crypto_value {
	my ($amount, $asset) = @_;
	return undef unless defined $amount && $amount =~ /-?\d/;
	my $rate = &crypto_rate($asset);
	return undef unless defined $rate;
	require Math::BigFloat;
	my $v = Math::BigFloat->new("$amount");
	$v->bmul(Math::BigFloat->new("$rate"));
	return $v->numify;
}

sub crypto_transaction {
	my ($data) = @_;
	my $d = ref $data eq 'HASH' ? $data : eval { decode_json($data || '') };
	my $c = ref $d eq 'HASH' ? $d->{'crypto'} : undef;
	return ref $c eq 'HASH' ? $c : undef;
}

# One snapshot for every asset and every fiat code. The request is public and
# keyless; an offline house keeps its last snapshot rather than losing the rates.
sub crypto_rates_refresh {
	my ($opts) = @_;
	$opts ||= {};
	return { ok => 0, error => 'crypto is off' } unless &crypto_enabled || $opts->{'force'};
	require Mojo::UserAgent;
	my $base = &crypto_report_currency();
	# Coinbase and open.er-api.com both serve a public CA certificate: there is
	# nothing self-signed to accept here, so verification stays on.
	my $ua = Mojo::UserAgent->new(connect_timeout => 8, inactivity_timeout => 12, request_timeout => 20);
	my (%rates, $source);
	my $res = eval { $ua->get('https://api.coinbase.com/v2/exchange-rates?currency=' . $base)->result };
	if ($res && $res->is_success) {
		my $json = eval { decode_json($res->body) };
		my $raw = ref $json eq 'HASH' ? $json->{'data'}->{'rates'} : undef;
		if (ref $raw eq 'HASH') {
			my %known = map { $_->{'coinbase'} => 1 } @crypto_asset_list;
			my %fiat = map { $_->{'code'} => 1 } @crypto_fiat_table;
			foreach my $code ( keys %{$raw} ) {
				next unless $fiat{$code} || $known{$code};
				my $v = $raw->{$code};
				next unless defined $v && $v =~ /^\d/ && $v > 0;
				$rates{$code} = 1 / $v;
			}
			$source = 'coinbase' if scalar keys %rates > 3;
		}
	}
	if (!$source) {
		my $res2 = eval { $ua->get('https://open.er-api.com/v6/latest/' . $base)->result };
		if ($res2 && $res2->is_success) {
			my $json2 = eval { decode_json($res2->body) };
			my $raw2 = ref $json2 eq 'HASH' ? $json2->{'rates'} : undef;
			if (ref $raw2 eq 'HASH') {
				my %fiat = map { $_->{'code'} => 1 } @crypto_fiat_table;
				foreach my $code ( keys %{$raw2} ) {
					next unless $fiat{$code};
					my $v = $raw2->{$code};
					next unless defined $v && $v =~ /^\d/ && $v > 0;
					$rates{$code} = 1 / $v;
				}
				$source = 'open.er-api' if scalar keys %rates > 3;
			}
		}
	}
	return { ok => 0, error => 'no rate source answered' } unless $source;
	# A fiat-only fallback keeps the coins from the previous snapshot: a stale
	# coin rate is better than a wallet that cannot be valued.
	if ($source ne 'coinbase') {
		my $old = &crypto_rates_read();
		my %coin = map { $_->{'coinbase'} => 1 } @crypto_asset_list;
		foreach my $code ( keys %{ $old->{'rates'} } ) {
			$rates{$code} = $old->{'rates'}->{$code} if $coin{$code} && !exists $rates{$code};
		}
	}
	$rates{$base} = 1 unless exists $rates{$base};
	my $written = &crypto_rates_write(\%rates, $source, $base);
	# The Measures app's PV column is a reading of the same snapshot.
	eval { &crypto_measures_sync(); };
	# The same snapshot feeds the optional history: one measure appointment
	# every six hours, in place of the app and appointment that used to do it.
	eval { &crypto_tracking_tick(); };
	return { ok => 1, source => $source, base => $base, count => scalar keys %rates, at => $written->{'at'} };
}

# What each wallet holds and what it is worth. Native units follow the signed
# amount stored on the transaction (income positive, expense negative, a
# transfer leg signed by its own direction); the money column is the signed
# total, exactly the figure the ledger's account balance uses.
sub crypto_wallets_report {
	my $accounts = &crypto_accounts();
	my $mode = lc(&setting_grabber({ app => 'crypto', setting => 'valuation', device => 'all' }) || 'cost');
	$mode = 'market' if $mode eq 'market';
	$mode = 'cost' unless $mode eq 'market';
	require Math::BigFloat;
	foreach my $w ( @{$accounts} ) {
		my $rows = &db_query("select total, data, movement from appointments where account = ? and type = 'transaction'", $w->{'app'})->hashes;
		my $native = Math::BigFloat->new(0);
		my $book = 0;
		my $count = 0;
		foreach my $r ( @{$rows} ) {
			my $c = &crypto_transaction($r->{'data'});
			next unless $c && defined $c->{'amount'} && $c->{'amount'} =~ /-?\d/;
			next unless uc($c->{'asset'} || '') eq $w->{'asset'};
			$native->badd(Math::BigFloat->new("$c->{'amount'}"));
			$book += ($r->{'total'} || 0) + 0;
			$count++;
		}
		my $rate = &crypto_rate($w->{'asset'});
		$w->{'native'} = $native->bstr();
		$w->{'native_display'} = &crypto_amount_format($w->{'native'}, $w->{'asset'});
		$w->{'book'} = $book;
		$w->{'rate'} = $rate;
		$w->{'market'} = defined $rate ? ($native * $rate)->numify : undef;
		$w->{'value'} = $mode eq 'market' && defined $w->{'market'} ? $w->{'market'} : $book;
		$w->{'valuation'} = $mode;
		$w->{'count'} = $count;
		$w->{'address_short'} = length($w->{'address'}) > 18
			? substr($w->{'address'}, 0, 10) . '…' . substr($w->{'address'}, -6)
			: $w->{'address'};
	}
	return $accounts;
}

# ---- one address per invoice -------------------------------------------------
# The wallet's account xpub makes a fresh receiving address from the external
# chain. The row lives in crypto_address (synced like any other table) so an
# invoice keeps its address across edits, peers and reprints. A wallet with no
# xpub falls back to the single address saved on the account, exactly as before.
sub crypto_invoice_wallet {
	my ($asset) = @_;
	$asset = uc($asset || 'BTC');
	my @wallets = @{ &crypto_accounts() };
	my @same = grep { ($_->{'asset'} || '') eq $asset } @wallets;
	my ($with_key) = grep { ($_->{'xpub'} || '') ne '' } @same;
	return $with_key if $with_key;
	return $same[0] if @same;
	return undef;
}

# A wallet field that must be the same on every machine (the xpub, and the
# address it falls back to). A shared row wins even when it is empty, so
# clearing the field on one machine is not undone by a stale device row.
sub crypto_wallet_setting {
	my ($app, $setting) = @_;
	return '' unless defined $app && length $app;
	my $shared = &setting_grabber({ app => $app, setting => $setting, device => 'all' });
	return $shared if defined $shared;
	return &setting_grabber({ app => $app, setting => $setting });
}

# Read the address an invoice already owns. Never writes: the public invoice
# page and the print view call this, and a GET must not allocate.
sub crypto_invoice_address_read {
	my ($app, $invoice) = @_;
	return undef unless defined $app && length $app && defined $invoice && length $invoice;
	my $q = &db_query("select * from crypto_address where app = ? and invoice_uuid = ? order by server_time desc limit 1", $app, $invoice);
	my $row = $q ? $q->hashes->[0] : undef;
	return { %{$row}, existing => 1 } if $row;
	my $static = &crypto_wallet_setting($app, 'wallet_address') || '';
	my $xpub = &crypto_wallet_setting($app, 'wallet_xpub') || '';
	return { address => $static, static => 1, missing => 1 } if length $xpub;
	return { address => $static, static => 1 };
}

# Reserve this invoice's address. Idempotent: a second call returns the same
# row. insert or ignore keeps two machines that allocated the same index while
# apart from failing the insert; the loser simply takes the next index.
sub crypto_invoice_address {
	my ($opts) = @_;
	my $app = $opts->{'app'};
	my $invoice = $opts->{'invoice'};
	return undef unless defined $app && length $app && defined $invoice && length $invoice;
	my $found = &crypto_invoice_address_read($app, $invoice);
	return $found unless $found && $found->{'missing'};
	my $static = $found->{'address'} || '';
	my $xpub = &crypto_wallet_setting($app, 'wallet_xpub') || '';
	my $x = &crypto_xpub_decode($xpub);
	return { address => $static, static => 1, error => 'the xpub could not be read' } unless $x;
	my $q = &db_query("select max(addr_index) as m from crypto_address where app = ?", $app);
	my $row = $q ? $q->hashes->[0] : undef;
	my $next = (defined $row && defined $row->{'m'}) ? $row->{'m'} + 1 : 0;
	for my $try (0 .. 7) {
		my $index = $next + $try;
		my $a = &crypto_xpub_address($x, $index);
		last unless $a;
		my $now = &rightNow();
		my $uuid = &random_string_creator(40);
		&db_query("insert or ignore into crypto_address (uuid, server_time, ost, app, asset, network, address, derivation, addr_index, path, invoice_uuid, issued_at) values (?,?,?,?,?,?,?,?,?,?,?,?)",
			$uuid, $now, $now, $app, 'BTC', $a->{'net'}, $a->{'address'}, $a->{'script'}, $index, $a->{'path'}, $invoice, $now);
		my $check = &db_query("select * from crypto_address where app = ? and invoice_uuid = ? order by server_time desc limit 1", $app, $invoice);
		my $hit = $check ? $check->hashes->[0] : undef;
		return { %{$hit}, allocated => 1 } if $hit;
	}
	return { address => $static, static => 1, error => 'no free address' };
}

# ---- currency tracking ------------------------------------------------------
# The old way to keep a currency history was an app with an appointment that
# wrote a measure every few hours. The checkbox in Configure -> Plat -> Crypto
# does the same job from the rate snapshot: one appointment of type measure in
# the house's currency app every six hours, carrying every tracked fiat code, so
# the Measures app charts it and no appointment has to run.
sub crypto_tracking_on {
	my $v = &setting_grabber({ app => 'crypto', setting => 'tracking', device => 'all' });
	return (defined $v && $v eq 'on') ? 1 : 0;
}

# The app the history goes to. An explicit choice wins; otherwise adopt the app
# the house already uses for currency measures, so its existing charts carry on.
sub crypto_tracking_app {
	my $pref = &setting_grabber({ app => 'crypto', setting => 'tracking_app', device => 'all' });
	if (defined $pref && length $pref) {
		$pref = &unformat_name($pref);
		return $pref if length $pref;
	}
	foreach my $a ( qw/canadian_dollar currency exchange_rates/ ) {
		my $row = &db_query("select 1 from settings where app = ? and setting = 'app_measures' limit 1", $a)->hashes->[0];
		return $a if $row;
	}
	return 'currency';
}

sub crypto_tracking_interval { return 6 * 60 * 60 * 1000 }

sub crypto_tracking_definitions {
	my ($app) = @_;
	my $row = &db_query("select value from settings where app = ? and setting = 'app_measures' order by server_time desc limit 1", $app)->hashes->[0];
	return {} unless $row;
	my $defs = eval { decode_json($row->{'value'}) };
	return ref $defs eq 'HASH' ? $defs : {};
}

# The app's measures can live on more than one device; update every row that is
# there rather than the one this worker happens to be running as.
sub crypto_tracking_definitions_write {
	my ($app, $defs) = @_;
	return 0 unless ref $defs eq 'HASH';
	my $json = encode_json($defs);
	my $devices = &db_query("select distinct device from settings where app = ? and setting = 'app_measures'", $app)->hashes;
	my @dev = map { $_->{'device'} } @{$devices};
	@dev = ( &device_setter() ) unless scalar @dev;
	foreach my $d ( @dev ) {
		next unless defined $d && length $d;
		&setting_setter({ app => $app, setting => 'app_measures', value => $json, device => $d });
	}
	return 1;
}

# The Measures app's PV column reads the same snapshot the Crypto panel shows:
# one unit of a code, valued in the house's reporting currency. The fiat rows
# Measures already holds are updated in place; every enabled coin gets a row of
# its own, so a market price has somewhere to sit. Called after a refresh and
# whenever Measures opens, so a snapshot taken while the panel was closed still
# fills the column without waiting for the next half-hour.
sub crypto_measures_sync {
	my $rates = &crypto_rates_read();
	my $table = $rates->{'rates'};
	return 0 unless ref $table eq 'HASH' && scalar keys %{$table};
	my $base = $rates->{'base'} || &crypto_report_currency();
	my $base_v = $table->{$base};
	$base_v = 1 unless defined $base_v && $base_v > 0;
	my $raw = &setting_grabber({ app => 'measures', setting => 'measures' });
	my $measures = eval { decode_json($raw) };
	return 0 unless ref $measures eq 'HASH' && scalar keys %{$measures};
	my $changed = 0;
	foreach my $k ( keys %{$measures} ) {
		next unless ref $measures->{$k} eq 'HASH';
		# only a code-shaped row (USD, EUR, JPY) names a snapshot unit
		next unless uc($k) eq $k && $k =~ /^[A-Z]{3}$/;
		my $v = $table->{$k};
		next unless defined $v && $v > 0;
		my $per = $v / $base_v;
		my $pv = $per >= 1 ? sprintf('%.2f', $per) : sprintf('%.6f', $per);
		next if defined $measures->{$k}->{'pv'} && $measures->{$k}->{'pv'} eq $pv;
		$measures->{$k}->{'pv'} = $pv;
		$changed++;
	}
	foreach my $code ( @{ &crypto_enabled_assets() } ) {
		my $v = $table->{$code};
		next unless defined $v && $v > 0;
		my $asset = &crypto_asset($code);
		my $row = $measures->{$code};
		if (ref $row ne 'HASH') {
			$row = $measures->{$code} = {
				name => ($asset->{'name'} || $code),
				types => [ 'currency' ],
				symbol => ($asset->{'symbol'} || ''),
				uuid => &random_string_creator(26),
			};
			$changed++;
		}
		my $per = $v / $base_v;
		my $pv = $per >= 1 ? sprintf('%.2f', $per) : sprintf('%.6f', $per);
		next if defined $row->{'pv'} && $row->{'pv'} eq $pv;
		$row->{'pv'} = $pv;
		$changed++;
	}
	return 0 unless $changed;
	&setting_setter({ app => 'measures', setting => 'measures', value => encode_json($measures) });
	return $changed;
}

sub crypto_tracking_tick {
	my ($opts) = @_;
	$opts ||= {};
	return { ok => 0, error => 'tracking is off' } unless &crypto_tracking_on;
	my $now = &rightNow();
	my $last = &setting_grabber({ app => 'crypto', setting => 'tracked_at', device => 'all' });
	if (!$opts->{'force'} && defined $last && $last =~ /^\d+$/ && $now - $last < &crypto_tracking_interval) {
		return { ok => 0, error => 'not due yet', at => $last };
	}
	my $rates = &crypto_rates_read();
	my $table = $rates->{'rates'} || {};
	return { ok => 0, error => 'no rate snapshot' } unless scalar keys %{$table};
	my $base = $rates->{'base'} || &crypto_report_currency();
	my $base_v = $table->{$base};
	$base_v = 1 unless defined $base_v && $base_v > 0;
	my $app = &crypto_tracking_app();
	my $defs = &crypto_tracking_definitions($app);
	if (!scalar keys %{$defs}) {
		return { ok => 0, error => 'no measures app yet' } unless $opts->{'create'};
		# An app that already exists only needs its measure definitions; a name
		# nobody has used yet is initialized like any other app.
		my $exists = &db_query('select 1 from settings where app = ? limit 1', $app)->hashes->[0]
			|| &db_query('select 1 from appointments where app = ? limit 1', $app)->hashes->[0];
		if (!$exists) {
			my $init = &setting_initializer($app, $now);
			$app = $init->{'app'} if ref $init eq 'HASH' && $init->{'app'};
		}
		$defs = &crypto_tracking_definitions($app);
	}
	my (@entries, $count);
	$count = 0;
	foreach my $f ( @crypto_fiat_table ) {
		next if $f->{'code'} eq $base;   # the base against itself is always 1
		next if $count >= 50;            # the top fifty the source answers
		my $v = $table->{ $f->{'code'} };
		next unless defined $v && $v > 0;
		my $per_base = $base_v / $v;     # units of this code per 1 report unit
		my $shown = sprintf('%.6f', $per_base);
		push @entries, { $f->{'measure'} => $shown, ts => $now, uuid => &random_string_creator(28) };
		$defs->{ $f->{'measure'} } = {
			type => 'number',
			unit => $f->{'code'},
			value => $shown,
			name => $f->{'name'},
		};
		$count++;
	}
	return { ok => 0, error => 'no currencies to record' } unless scalar @entries;
	my $uuid = &random_string_creator(40);
	&db_insert('appointments', {
		app => $app,
		type => 'measure',
		timestamp => $now,
		duration => 1000,
		measures => encode_json(\@entries),
		server_time => $now,
		uuid => $uuid,
		device => &device_setter(),
	});
	&crypto_tracking_definitions_write($app, $defs);
	&setting_setter({ app => 'crypto', setting => 'tracked_at', value => $now, device => 'all' });
	return { ok => 1, app => $app, count => $count, uuid => $uuid, at => $now };
}

# The Store's two directions, named for what the house is doing: an income
# movement is a sale and an expense movement is a purchase. The stored movement
# values do not change - only the words on the Store's own dropdown.
sub store_movement_label {
	my ($m) = @_;
	$m = '' unless defined $m;
	return &lang('store.selling') if $m eq 'income';
	return &lang('store.buying') if $m eq 'expense';
	return &lang('common.' . $m) if $m eq 'transfer' || $m eq 'inventory';
	return &format_name($m);
}

# ---- payment proofs ---------------------------------------------------------
# A payer's crest signs a statement of what was sent for which document; the
# payee signs the same bytes back. The code travels like a crest code (PAY1Z:
# deflated JSON), so it can be pasted or scanned. This is an attestation by the
# two houses, not a chain check: the txid is carried, not verified here.
sub payment_proof_statement {
	my ($record) = @_;
	return undef unless ref $record eq 'HASH';
	my $copy = { %$record };
	delete $copy->{'payer_sig'};
	delete $copy->{'payee_sig'};
	return JSON::PP->new->canonical(1)->encode($copy);
}

sub payment_proof_build {
	my ($record, $priv) = @_;
	return undef unless ref $record eq 'HASH' && defined $priv && length $priv == 32;
	my $json = &payment_proof_statement($record);
	return undef unless defined $json;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($priv, 'private');
	my $sig = $key->sign_message($json);
	return undef unless defined $sig && length $sig == 64;
	return { %$record, payer_sig => encode_base64($sig, '') };
}

sub payment_proof_verify {
	my ($record) = @_;
	return 0 unless ref $record eq 'HASH';
	return 0 unless ($record->{'format'} || '') eq 'jawnos-payment';
	return 0 unless ($record->{'version'} || 0) == 1;
	my $payer = ref $record->{'payer'} eq 'HASH' ? $record->{'payer'} : {};
	my $pub = eval { decode_base64($payer->{'pubkey'} || '') };
	my $sig = eval { decode_base64($record->{'payer_sig'} || '') };
	return 0 unless defined $pub && length $pub == 32 && defined $sig && length $sig == 64;
	my $json = &payment_proof_statement($record);
	return 0 unless defined $json;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($pub, 'public');
	return $key->verify_message($sig, $json) ? 1 : 0;
}

sub payment_proof_countersign {
	my ($record, $priv) = @_;
	return undef unless ref $record eq 'HASH' && defined $priv && length $priv == 32;
	my $json = &payment_proof_statement($record);
	return undef unless defined $json;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($priv, 'private');
	my $sig = $key->sign_message($json);
	return undef unless defined $sig && length $sig == 64;
	return { %$record, payee_sig => encode_base64($sig, '') };
}

sub payment_proof_verify_payee {
	my ($record, $pubkey) = @_;
	return 0 unless ref $record eq 'HASH' && defined $pubkey && length $pubkey;
	my $pub = eval { decode_base64($pubkey) };
	my $sig = eval { decode_base64($record->{'payee_sig'} || '') };
	return 0 unless defined $pub && length $pub == 32 && defined $sig && length $sig == 64;
	my $json = &payment_proof_statement($record);
	return 0 unless defined $json;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($pub, 'public');
	return $key->verify_message($sig, $json) ? 1 : 0;
}

sub payment_proof_code {
	my ($record) = @_;
	return undef unless ref $record eq 'HASH';
	my $json = JSON::PP->new->canonical(1)->encode($record);
	require Compress::Zlib;
	my $packed = Compress::Zlib::compress($json);
	return undef unless defined $packed && length $packed;
	return 'PAY1Z:' . encode_base64($packed, '');
}

sub payment_proof_parse {
	my ($code) = @_;
	return undef unless defined $code;
	$code =~ s/^\s+|\s+$//g;
	return undef unless $code =~ /^PAY1Z:(.*)$/is;
	my $packed = $1;
	$packed =~ s/\s+//g;
	my $bytes = eval { decode_base64($packed) };
	return undef unless defined $bytes && length $bytes;
	require Compress::Zlib;
	$bytes = Compress::Zlib::uncompress($bytes);
	return undef unless defined $bytes && length $bytes;
	my $record = eval { decode_json($bytes) };
	return ref $record eq 'HASH' ? $record : undef;
}

# A native amount and a claimed amount are equal when they are within 1% - a
# rate moves between quoting and sending, but not by more than that in practice.
sub payment_amount_matches {
	my ($a, $b) = @_;
	return 0 unless defined $a && defined $b && "$a" =~ /\d/ && "$b" =~ /\d/;
	my $x = "$a" + 0;
	my $y = "$b" + 0;
	return 1 if $x == $y;
	return 0 unless $y != 0;
	return abs($x - $y) / abs($y) <= 0.01 ? 1 : 0;
}

# ---- online payments (Configure -> Plat -> Pay) ----------------------------
#
# Four ways for a customer to settle an invoice from the public invoice page:
# Stripe, Square and PayPal create a hosted checkout for the exact balance and
# record the payment when the provider says it is paid; Interac e-Transfer has
# no consumer API, so JawnOS reads the notification letters already arriving in
# the mailbox (or accepts a signed forwarder) and stages them for the seller.
# Keys are sealed like an AI key and never leave the server.
sub pay_secret_names {
	return qw(
		stripe_secret stripe_webhook_secret
		square_access_token square_webhook_key
		paypal_secret paypal_webhook_id
		interac_hook_token
	);
}

# Read a pay setting. The house shares these the way it shares the language, so
# a phone and the desk agree on which provider is on.
sub pay_setting {
	my ($name, $default) = @_;
	return $default unless defined $name && length $name;
	my $v = &setting_grabber({ app => 'pay', setting => $name, device => 'all' });
	return (defined $v && length $v) ? $v : $default;
}

# A secret is stored sealed; a value written by an older build (or a plain row
# replayed by a peer) still opens, so a key is never lost to a format change.
sub pay_secret_read {
	my ($name) = @_;
	my $v = &pay_setting($name, '');
	return '' unless defined $v && length $v;
	# A pay key is always sealed. Without the vault it cannot be opened, and a
	# provider that looks ready but cannot authenticate is worse than one that
	# stays hidden, so a locked vault reads as an empty key.
	my $suds = eval { &suds_grabber() };
	return '' unless $suds;
	my $d = eval { &note_decrypter($suds, $v) };
	return (defined $d && length $d) ? $d : '';
}

sub pay_on {
	return &pay_setting('enabled', 'off') eq 'on' ? 1 : 0;
}

sub pay_currency {
	return &crypto_report_currency();
}

sub pay_providers {
	return [
		{ id => 'stripe',  label => 'Stripe',            kind => 'card' },
		{ id => 'square',  label => 'Square',            kind => 'card' },
		{ id => 'paypal',  label => 'PayPal',            kind => 'wallet' },
		{ id => 'interac', label => 'Interac e-Transfer', kind => 'transfer' },
	];
}

# A provider is offered only when the house turned it on AND it has what it
# needs to work. The public page reads this same answer, so a half-filled panel
# never shows a button that cannot complete.
sub pay_provider_ready {
	my ($provider) = @_;
	return 0 unless &pay_on;
	$provider = lc($provider || '');
	return 0 unless &pay_setting($provider . '_enabled', 'off') eq 'on';
	if ($provider eq 'stripe') {
		return length(&pay_secret_read('stripe_secret')) ? 1 : 0;
	}
	if ($provider eq 'square') {
		return (length(&pay_secret_read('square_access_token')) && length(&pay_setting('square_location_id', ''))) ? 1 : 0;
	}
	if ($provider eq 'paypal') {
		return (length(&pay_setting('paypal_client_id', '')) && length(&pay_secret_read('paypal_secret'))) ? 1 : 0;
	}
	if ($provider eq 'interac') {
		return length(&pay_setting('interac_email', '')) ? 1 : 0;
	}
	return 0;
}

# The accounts a payment may be booked into. An account is an app whose part of
# speech is account, the same list the App tab and a transaction use.
sub pay_accounts {
	my $rows = &db_query("select distinct app from settings where setting in ('pos','mab') and value = 'account' and app is not null and app != '' order by app")->hashes;
	my @out;
	foreach my $r ( @{$rows} ) {
		my $tender = &setting_grabber({ app => $r->{'app'}, setting => 'payment_type' });
		push @out, {
			app => $r->{'app'},
			name => &format_name($r->{'app'}),
			payment_type => ($tender || ''),
		};
	}
	return \@out;
}

# Where a provider's money lands. The panel's own choice wins; without one, the
# first account that names the tender is a sensible fallback so a house that
# never opened this panel still records the money somewhere.
sub pay_account_for {
	my ($provider) = @_;
	my $picked = &pay_setting($provider . '_account', '');
	return $picked if length $picked;
	my $want = ($provider eq 'interac') ? 'interac' : 'credit';
	my $row = &db_query("select app from settings where setting = 'payment_type' and lower(value) = ? and app is not null and app != '' order by app limit 1", $want)->hashes->[0];
	return $row->{'app'} if $row && $row->{'app'};
	my $any = &db_query("select distinct app from settings where setting in ('pos','mab') and value = 'account' and app is not null and app != '' order by app limit 1")->hashes->[0];
	return ($any && $any->{'app'}) ? $any->{'app'} : '';
}

1;
