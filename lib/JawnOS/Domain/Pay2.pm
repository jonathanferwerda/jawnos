package subs;

# Pay2: extracted from subroutines.pl (package subs). Loaded on
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

our %clock_long_alarm_files;
# ---------------------------------------------------------------------------
# The Clock app: alarms, timers, and the little that has to live server-side.
#
# Alarms and timers are rows in the `settings` table under app 'clock' so they
# survive a restart and ride the house's usual per-device sync. They are small
# JSON arrays, capped at ten each. Every read-modify-write takes one flock so a
# web worker saving an alarm cannot lose the alarm the firing loop just marked,
# and the firing loop itself runs from Alarm.pl.
# ---------------------------------------------------------------------------
our @clock_sound_files;
our $device;
our %m;

# The provider sends the customer back here. Nothing the browser says is
# trusted: the provider's own record is read and that is what is recorded.
sub pay_return_handle {
	my ($provider, $c) = @_;
	$provider = lc($provider || '');
	my $base = &pay_public_base($c);
	my $cid = $c->param('cid') || '';
	my ($cid_uuid, $cid_cx) = split /\|/, $cid, 2;
	$cid_uuid =~ s/[?&].*$// if defined $cid_uuid;
	$cid_cx =~ s/[?&].*$// if defined $cid_cx;
	my $back = sub {
		my ($uuid, $cx) = @_;
		return length($uuid || '') ? $base . '/public_view/invoice/' . url_escape($uuid) . '/' . url_escape($cx || '') : '';
	};
	if ($provider eq 'stripe') {
		my $id = $c->param('session_id') || '';
		if (!length $id && length($cid_uuid || '')) {
			my $saved = &pay_session_find('stripe', $cid_uuid);
			$id = $saved->{'session_id'} if $saved;
		}
		my $session = &pay_stripe_session_read($id);
		return { ok => 0, pending => 1, message => 'Stripe has not confirmed this payment yet. Refresh this page in a moment; the invoice will update when the confirmation arrives.' } unless $session;
		my $meta = ref $session->{'metadata'} eq 'HASH' ? $session->{'metadata'} : {};
		my $uuid = $meta->{'invoice_uuid'} || $cid_uuid || '';
		my $cx = $meta->{'cx'} || $cid_cx || '';
		if (($session->{'payment_status'} || '') ne 'paid') {
			return { ok => 0, pending => 1, uuid => $uuid, cx => $cx, invoice_url => $back->($uuid, $cx), message => 'Stripe is still processing this payment. Refresh this page in a moment; the invoice will update when it is confirmed.' };
		}
		my $out = &pay_record_payment({
			uuid => $uuid, cx => $cx, provider => 'stripe', ref => ($session->{'id'} || $id),
			amount => &pay_major(($session->{'amount_total'} || 0), uc($session->{'currency'} || '')), currency => uc($session->{'currency'} || ''),
			note => 'Stripe checkout',
		});
		$out->{'invoice_url'} = $back->($uuid, $cx);
		return $out;
	}
	if ($provider eq 'square') {
		my $order_id = $c->param('orderId') || $c->param('order_id') || '';
		my $uuid = $cid_uuid || $c->param('uuid') || '';
		my $cx = $cid_cx || $c->param('cx') || '';
		my $saved = &pay_session_find('square', $uuid);
		$order_id = $saved->{'order_id'} if !length $order_id && $saved;
		my $order = length $order_id ? &pay_square_order_read($order_id) : undef;
		return { ok => 0, pending => 1, uuid => $uuid, cx => $cx, invoice_url => $back->($uuid, $cx), message => 'Square has not confirmed this payment yet. Refresh this page in a moment; the invoice will update when the confirmation arrives.' } unless $order;
		my $meta = ref $order->{'metadata'} eq 'HASH' ? $order->{'metadata'} : {};
		$uuid = $meta->{'invoice_uuid'} || $order->{'reference_id'} || $uuid;
		$cx = $meta->{'cx'} || $cx;
		my $tender = ref $order->{'tenders'} eq 'ARRAY' ? ($order->{'tenders'}->[0] || {}) : {};
		if (uc($order->{'state'} || '') ne 'COMPLETED' || !$tender->{'payment_id'}) {
			return { ok => 0, pending => 1, uuid => $uuid, cx => $cx, invoice_url => $back->($uuid, $cx), message => 'Square is still processing this payment. Refresh this page in a moment; the invoice will update when it is confirmed.' };
		}
		my $money = ref $tender->{'amount_money'} eq 'HASH' ? $tender->{'amount_money'} : (ref $order->{'total_money'} eq 'HASH' ? $order->{'total_money'} : {});
		my $out = &pay_record_payment({
			uuid => $uuid, cx => $cx, provider => 'square', ref => $tender->{'payment_id'},
			amount => &pay_major(($money->{'amount'} || 0), ($money->{'currency'} || '')), currency => ($money->{'currency'} || ''),
			note => 'Square checkout',
		});
		$out->{'invoice_url'} = $back->($uuid, $cx);
		return $out;
	}
	if ($provider eq 'paypal') {
		my $order_id = $c->param('token') || '';
		my $uuid = $cid_uuid || $c->param('uuid') || '';
		my $cx = $cid_cx || $c->param('cx') || '';
		if (!length $order_id && length($uuid || '')) {
			my $saved = &pay_session_find('paypal', $uuid);
			$order_id = $saved->{'order_id'} if $saved;
		}
		my $order = length $order_id ? &pay_paypal_order_read($order_id) : undef;
		return { ok => 0, pending => 1, uuid => $uuid, cx => $cx, invoice_url => $back->($uuid, $cx), message => 'PayPal has not confirmed this payment yet. Refresh this page in a moment; the invoice will update when the confirmation arrives.' } unless $order;
		my $unit = ref $order->{'purchase_units'} eq 'ARRAY' ? ($order->{'purchase_units'}->[0] || {}) : {};
		$uuid = $unit->{'reference_id'} || $uuid;
		if (uc($order->{'status'} || '') eq 'APPROVED') {
			my $cap = &pay_paypal_capture($order_id);
			if ($cap->{'ok'}) { $order = $cap->{'data'}; }
		}
		if (uc($order->{'status'} || '') ne 'COMPLETED') {
			return { ok => 0, pending => 1, uuid => $uuid, cx => $cx, invoice_url => $back->($uuid, $cx), message => 'PayPal is still processing this payment. Refresh this page in a moment; the invoice will update when it is confirmed.' };
		}
		my $out = &pay_paypal_capture_record($order, 'PayPal checkout');
		$out->{'invoice_url'} = $back->($uuid, $cx);
		return $out;
	}
	return { ok => 0, message => 'That payment method is not available.' };
}

# A small, honest check from the panel: the key works and the provider answers.
sub pay_test_provider {
	my ($provider) = @_;
	$provider = lc($provider || '');
	if ($provider eq 'stripe') {
		my $secret = &pay_secret_read('stripe_secret');
		return { ok => 0, message => 'No secret key is set.' } unless length $secret;
		my $res = eval { &pay_ua()->get('https://api.stripe.com/v1/balance' => { Authorization => 'Bearer ' . $secret })->result };
		my $json = ($res && $res->body) ? (eval { decode_json($res->body) } || {}) : {};
		return { ok => ($res && $res->is_success) ? 1 : 0, message => ($res && $res->is_success) ? 'Stripe answered. The key works.' : ('Stripe: ' . ($json->{'error'}->{'message'} || 'no answer')) };
	}
	if ($provider eq 'square') {
		my $token = &pay_secret_read('square_access_token');
		return { ok => 0, message => 'No access token is set.' } unless length $token;
		my $res = eval { &pay_ua()->get(&pay_square_base() . '/v2/locations' => { Authorization => 'Bearer ' . $token })->result };
		my $json = ($res && $res->body) ? (eval { decode_json($res->body) } || {}) : {};
		if ($res && $res->is_success) {
			my $locations = ref $json->{'locations'} eq 'ARRAY' ? scalar @{ $json->{'locations'} } : 0;
			return { ok => 1, message => 'Square answered with ' . $locations . ' location' . ($locations == 1 ? '' : 's') . '.' };
		}
		my $why = ref $json->{'errors'} eq 'ARRAY' && @{ $json->{'errors'} } ? ($json->{'errors'}->[0]->{'detail'} || '') : 'no answer';
		return { ok => 0, message => 'Square: ' . $why };
	}
	if ($provider eq 'paypal') {
		my ($token, $err) = &pay_paypal_token();
		return { ok => $token ? 1 : 0, message => $token ? 'PayPal answered. The client id and secret work.' : ('PayPal: ' . ($err || 'no answer')) };
	}
	if ($provider eq 'interac') {
		my $email = &pay_setting('interac_email', '');
		return { ok => length $email ? 1 : 0, message => length $email ? 'Interac payments go to ' . $email . '.' : 'No Interac email is set.' };
	}
	return { ok => 0, message => 'Unknown payment method.' };
}

# ---- Interac e-Transfer -----------------------------------------------------
# There is no consumer API for an e-Transfer. The notification letter is the
# source of truth, so JawnOS reads the ones already arriving in the mailbox, or
# accepts the same facts from a bank/aggregator that can forward them. A letter
# is staged for a person unless the house has said auto-record, and even then
# only when one invoice is an unmistakable match.
sub pay_interac_token {
	my $t = &pay_secret_read('interac_hook_token');
	return $t if length $t && $t =~ /^[A-Za-z0-9]{20,}$/;
	$t = &random_string_creator(40);
	my $sealed = eval { &note_encrypter(&suds_grabber(), $t) };
	return '' unless defined $sealed && length $sealed;
	&setting_setter({
		app => 'pay', setting => 'interac_hook_token',
		value => $sealed, device => 'all',
	});
	return $t;
}

sub pay_interac_currency {
	my $c = uc(&pay_setting('interac_currency', 'CAD'));
	$c = 'CAD' unless $c =~ /^[A-Z]{3}$/;
	return $c;
}

sub pay_interac_looks_like {
	my ($email, $subject, $body) = @_;
	my $from = lc($email || '');
	return 1 if $from =~ /\@(?:[a-z0-9-]+\.)*interac\.ca\b/;
	my $text = lc(($subject || '') . ' ' . ($body || ''));
	return 1 if $text =~ /interac\s*e-?transfer/;
	return 1 if $text =~ /transfert\s*(?:electronique|électronique)/;
	return 0;
}

# Pull out the few facts an e-Transfer letter carries. Anything it does not
# recognise stays empty rather than guessed, so a person can still match it.
sub pay_interac_parse {
	my ($subject, $body) = @_;
	my $text = ($subject || '') . "\n" . ($body || '');
	$text =~ s/<[^>]+>/ /g;
	$text =~ s/&nbsp;/ /gi;
	$text =~ s/&amp;/&/gi;
	$text =~ s/&[a-z]+;/ /gi;
	$text =~ s/\s+/ /g;
	my $amount = '';
	if ($text =~ /(?:sent you|vous a envoyé)\s+\$?\s*([0-9][0-9.,]*[.,][0-9]{2})/i) { $amount = $1; }
	elsif ($text =~ /([0-9][0-9.,]*[.,][0-9]{2})\s*\$/) { $amount = $1; }
	elsif ($text =~ /\$([0-9][0-9,]*\.[0-9]{2})/) { $amount = $1; }
	if (length $amount) {
		if ($amount =~ /,/ && $amount =~ /\./) { $amount =~ s/,//g; }
		elsif ($amount =~ /,/) { $amount =~ s/,/./g; }
		$amount =~ s/[^0-9.]//g;
	}
	my $sender = '';
	if ($subject =~ /INTERAC\s*e-?Transfert?\s*:\s*(.+?)\s+(?:(?:has\s+)?sent you|vous a envoyé)/i) { $sender = $1; }
	elsif ($text =~ /([A-Z][A-Za-z0-9 .'-]{1,70})\s+(?:(?:has\s+)?sent you|vous a envoyé)\s+\$?[0-9]/) { $sender = $1; }
	$sender =~ s/^\s+|\s+$//g;
	my $reference = '';
	$reference = $1 if $text =~ /(?:Reference|Numéro de référence)\s*(?:Number|No\.?)?\s*:?\s*([A-Z0-9]{6,})/i;
	my $memo = '';
	$memo = $1 if $text =~ /(?:Message|Memo)\s*:?\s*(.{0,200}?)(?:\s+Reference\s|\s+Numéro de référence\s|\s+To deposit\s|\s+Pour déposer\s|\s+Autodeposit\s|\s+Dépôt automatique\s|\s+You can deposit\s|$)/i;
	$memo =~ s/^\s+|\s+$//g;
	my $deposited = ($text =~ /automatically deposited|has been deposited|deposited to your account|was deposited|automatic deposit|déposé automatiquement|a été déposé|déposé dans votre compte|dépôt automatique|dépôt direct/i) ? 1 : 0;
	my $pending = ($text =~ /security question|answer the question|to deposit your money|deposit your money|claim your money|question de sécurité|répondez à la question|pour déposer votre argent/i) ? 1 : 0;
	return {
		amount => 0 + ($amount || 0),
		sender => $sender,
		reference => $reference,
		memo => $memo,
		deposited => $deposited,
		pending => $pending,
		text => substr($text, 0, 2000),
	};
}

# Open invoices that could be the one this e-transfer is for. The score is
# deliberately simple: an invoice reference in the message is strongest, the
# exact balance next, then the sender's own address and name.
sub pay_interac_candidates {
	my ($parsed) = @_;
	$parsed ||= {};
	my $currency = &pay_interac_currency();
	my $base = &pay_currency();
	my $rate = ($currency eq $base) ? 1 : &exchange_rate($currency, $base);
	my $value = defined $rate && $rate > 0 ? ($parsed->{'amount'} || 0) * $rate : ($parsed->{'amount'} || 0);
	my $rows = &db_query("select * from appointments where type = 'invoice' order by timestamp desc limit 500")->hashes;
	my $hay = lc(join(' ', ($parsed->{'memo'} || ''), ($parsed->{'reference'} || ''), ($parsed->{'sender'} || '')));
	my @out;
	foreach my $inv ( @{$rows} ) {
		my ($data, $balance) = &pay_invoice_balance($inv);
		next if $balance <= 0.005;
		my $ref = &pay_invoice_ref($data);
		my $email = &setting_grabber({ app => $inv->{'app'}, setting => 'email' }) || '';
		my $score = 0;
		$score += 100 if length($ref || '') && index($hay, lc($ref)) >= 0;
		$score += 30 if defined $value && $value > 0 && abs($balance - $value) <= 0.01;
		$score += 20 if length($email || '') && lc($email) eq lc($parsed->{'email'} || '');
		my $name = &format_name($inv->{'app'});
		$score += 10 if length($parsed->{'sender'} || '') && (index(lc($name), lc($parsed->{'sender'})) >= 0 || index(lc($parsed->{'sender'}), lc($name)) >= 0);
		next unless $score > 0;
		push @out, {
			uuid => $inv->{'uuid'},
			id => ($data->{'id'} || $inv->{'uuid'}),
			balance => $balance,
			customer => $name,
			score => $score,
		};
	}
	@out = sort { $b->{'score'} <=> $a->{'score'} || $a->{'balance'} <=> $b->{'balance'} } @out;
	return (\@out, $value);
}

# Stage one notification. Auto-record happens only when the house asked for it,
# the money is actually deposited, and exactly one invoice names the reference.
sub pay_interac_stage {
	my ($parsed) = @_;
	$parsed ||= {};
	return { staged => 0, recorded => 0, error => 'no amount was read' } unless ($parsed->{'amount'} || 0) > 0;
	my ($candidates, $value) = &pay_interac_candidates($parsed);
	my $currency = &pay_interac_currency();
	my $key = 'interac:' . &sha256_hex(join('|',
		$parsed->{'mail_uuid'} || '', $parsed->{'reference'} || '',
		$parsed->{'amount'} || '', $parsed->{'sender'} || '', $parsed->{'memo'} || ''));
	$key = 'pay_interac:' . substr($key, 0, 56);
	my $existing = &db_select('cache', undef, { context => 'pay_interac', uuid => $key })->hashes->[0];
	return { staged => 0, recorded => 0, existing => 1 } if $existing;

	my $auto = (&pay_setting('interac_auto', 'off') eq 'on') ? 1 : 0;
	my $top = $candidates->[0];
	my $unique = (scalar @{$candidates} == 1) || ($top && (! $candidates->[1] || $top->{'score'} > $candidates->[1]->{'score'}));
	if ($auto && $parsed->{'deposited'} && $top && $unique && $top->{'score'} >= 100) {
		my $out = &pay_record_payment({
			uuid => $top->{'uuid'}, provider => 'interac',
			ref => ($parsed->{'reference'} || $parsed->{'mail_uuid'} || $key),
			amount => $parsed->{'amount'}, currency => $currency,
			note => trim_text(join(' ', 'Interac e-Transfer', ($parsed->{'sender'} ? 'from ' . $parsed->{'sender'} : ''), ($parsed->{'memo'} ? '- ' . $parsed->{'memo'} : ''))),
		});
		if ($out->{'ok'}) {
			&db_query('delete from cache where context = ? and uuid = ?', 'pay_interac', $key);
			return { staged => 0, recorded => 1, result => $out };
		}
	}

	my $now = &rightNow();
	&db_insert('cache', {
		uuid => $key,
		app => 'pay_interac',
		context => 'pay_interac',
		timestamp => $now,
		server_time => $now,
		warranty => $now + (30 * 86400000),
		data => encode_json({
			amount => ($parsed->{'amount'} || 0),
			value => $value,
			currency => $currency,
			sender => ($parsed->{'sender'} || ''),
			reference => ($parsed->{'reference'} || ''),
			memo => ($parsed->{'memo'} || ''),
			deposited => $parsed->{'deposited'} ? 1 : 0,
			pending => $parsed->{'pending'} ? 1 : 0,
			email => ($parsed->{'email'} || ''),
			mail_uuid => ($parsed->{'mail_uuid'} || ''),
			text => ($parsed->{'text'} || ''),
			candidates => $candidates,
			at => $now,
		}),
	});
	return { staged => 1, recorded => 0, key => $key, candidates => $candidates };
}

sub trim_text {
	my ($s) = @_;
	$s = '' unless defined $s;
	$s =~ s/\s+/ /g;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

sub pay_interac_scan {
	return { ok => 0, error => 'Interac e-Transfer is off' } unless &pay_on && &pay_provider_ready('interac');
	return { ok => 0, error => 'watching the inbox is off' } unless &pay_setting('interac_watch', 'off') eq 'on';
	my $suds = eval { &suds_grabber() };
	return { ok => 0, error => 'the vault is locked, so the notifications cannot be read' } unless $suds;
	my $rows = &db_query("select uuid, email, subject, body, timestamp from mailbox where status in ('inbox','archive') and email is not null and lower(email) like ? order by server_time desc limit 100", '%interac%')->hashes;
	my ($found, $staged, $recorded) = (0, 0, 0);
	foreach my $row ( @{$rows} ) {
		my $seen = &db_select('cache', undef, { context => 'pay_interac_seen', uuid => $row->{'uuid'} })->hashes->[0];
		next if $seen;
		my $subject = eval { &note_decrypter($suds, $row->{'subject'} || '') } || '';
		my $body = eval { &note_decrypter($suds, $row->{'body'} || '') } || '';
		next unless &pay_interac_looks_like($row->{'email'} || '', $subject, $body);
		$found++;
		my $parsed = &pay_interac_parse($subject, $body);
		$parsed->{'mail_uuid'} = $row->{'uuid'};
		$parsed->{'email'} = $row->{'email'} || '';
		my $out = eval { &pay_interac_stage($parsed) } || {};
		$staged++ if $out->{'staged'};
		$recorded++ if $out->{'recorded'};
		# Only mark the letter read when it produced something (a staged row, a
		# recorded payment, or a row that was already there). A letter whose body
		# could not be read is left for the next pass rather than lost.
		next unless $out->{'staged'} || $out->{'recorded'} || $out->{'existing'};
		my $now = &rightNow();
		&db_insert('cache', {
			uuid => $row->{'uuid'}, app => 'pay_interac_seen', context => 'pay_interac_seen',
			timestamp => $now, server_time => $now, warranty => $now + (30 * 86400000),
		});
	}
	&setting_setter({ app => 'pay', setting => 'interac_scanned_at', value => &rightNow(), device => 'all' });
	&db_query("delete from cache where context in ('pay_interac_seen') and cast(warranty as integer) > 0 and cast(warranty as integer) < ?", &rightNow());
	return { ok => 1, found => $found, staged => $staged, recorded => $recorded };
}

# What the panel lists: staged notifications with their best invoice matches,
# newest first. A candidate whose invoice has since been paid is dropped.
sub pay_interac_receipts {
	my $rows = &db_query("select * from cache where context = 'pay_interac' order by server_time desc limit 100")->hashes;
	my @out;
	my $now = &rightNow();
	foreach my $row ( @{$rows} ) {
		my $d = eval { decode_json($row->{'data'} || '') } || {};
		next if defined $row->{'warranty'} && $row->{'warranty'} =~ /^\d+$/ && $row->{'warranty'} < $now;
		my @cands;
		foreach my $c ( @{ ref $d->{'candidates'} eq 'ARRAY' ? $d->{'candidates'} : [] } ) {
			my $inv = &db_select('appointments', undef, { uuid => $c->{'uuid'} })->hashes->[0];
			next unless $inv;
			my ($data, $balance) = &pay_invoice_balance($inv);
			next if $balance <= 0.005;
			push @cands, {
				uuid => $inv->{'uuid'},
				id => ($data->{'id'} || $inv->{'uuid'}),
				customer => &format_name($inv->{'app'}),
				balance => $balance,
				score => ($c->{'score'} || 0),
			};
		}
		@cands = sort { $b->{'score'} <=> $a->{'score'} || $a->{'balance'} <=> $b->{'balance'} } @cands;
		push @out, {
			id => $row->{'uuid'},
			at => ($d->{'at'} || $row->{'server_time'} || 0),
			amount => ($d->{'amount'} || 0),
			value => ($d->{'value'} || 0),
			currency => ($d->{'currency'} || 'CAD'),
			sender => ($d->{'sender'} || ''),
			reference => ($d->{'reference'} || ''),
			memo => ($d->{'memo'} || ''),
			deposited => ($d->{'deposited'} ? 1 : 0),
			pending => ($d->{'pending'} ? 1 : 0),
			email => ($d->{'email'} || ''),
			candidates => \@cands,
		};
	}
	return \@out;
}

sub pay_interac_record {
	my ($id, $uuid, $actor) = @_;
	return { ok => 0, error => 'no notification was named' } unless defined $id && length $id;
	my $row = &db_select('cache', undef, { context => 'pay_interac', uuid => $id })->hashes->[0];
	return { ok => 0, error => 'that notification is no longer waiting' } unless $row;
	my $d = eval { decode_json($row->{'data'} || '') } || {};
	if (!length($uuid || '')) {
		my $top = ref $d->{'candidates'} eq 'ARRAY' ? $d->{'candidates'}->[0] : undef;
		$uuid = $top ? $top->{'uuid'} : '';
	}
	return { ok => 0, error => 'choose the invoice this e-transfer settles' } unless length($uuid || '');
	my $out = &pay_record_payment({
		uuid => $uuid, provider => 'interac',
		ref => ($d->{'reference'} || $d->{'mail_uuid'} || $id),
		amount => ($d->{'amount'} || 0), currency => ($d->{'currency'} || 'CAD'),
		note => trim_text(join(' ', 'Interac e-Transfer', ($d->{'sender'} ? 'from ' . $d->{'sender'} : ''), ($d->{'memo'} ? '- ' . $d->{'memo'} : ''), ($actor ? 'recorded by ' . $actor : ''))),
	});
	if ($out->{'ok'}) {
		&db_query('delete from cache where context = ? and uuid = ?', 'pay_interac', $id);
	}
	return $out;
}

sub pay_interac_ignore {
	my ($id) = @_;
	return { ok => 0, error => 'no notification was named' } unless defined $id && length $id;
	&db_query('delete from cache where context = ? and uuid = ?', 'pay_interac', $id);
	return { ok => 1 };
}

# A bank or aggregator that can see e-Transfer notifications posts the same
# facts here. The task token is the gate, exactly like the LoRaWAN uplink.
sub pay_interac_hook {
	my ($body, $token, $c) = @_;
	$body = {} unless ref $body eq 'HASH';
	my $want = &pay_interac_token();
	return { ok => 0, error => 'bad token' } unless length($want || '')
		&& length($token || '') && &secure_compare($token, $want);
	return { ok => 0, error => 'Interac e-Transfer is off' } unless &pay_on && &pay_provider_ready('interac');
	my $parsed = {
		amount => 0 + (($body->{'amount'} || '') =~ /([0-9]+(?:\.[0-9]+)?)/ ? $1 : 0),
		sender => trim_text($body->{'sender'} || ''),
		reference => trim_text($body->{'reference'} || ''),
		memo => trim_text($body->{'memo'} || $body->{'message'} || ''),
		deposited => ($body->{'deposited'} ? 1 : 0),
		pending => ($body->{'pending'} ? 1 : 0),
		email => trim_text($body->{'email'} || ''),
		text => trim_text($body->{'text'} || ''),
	};
	return { ok => 0, error => 'the notification has no amount' } unless $parsed->{'amount'} > 0;
	if (length($body->{'invoice'} || '')) {
		$parsed->{'memo'} = trim_text($parsed->{'memo'} . ' ' . $body->{'invoice'});
	}
	my $out = &pay_interac_stage($parsed);
	return { ok => 1, %{$out} };
}

sub clock_device {
	return &device_setter();
}

# Alarms are the house's, not one machine's: they live in a single settings row
# every machine reads, and each alarm names the machines that should ring it.
# Timers stay on the machine that started them (they are a countdown in a hand).
sub clock_alarm_store_device {
	return 'house';
}

# The machines an alarm can be shared with: this machine ("Me") first, then
# every peer the mesh knows. The value is the machine's signatorial, because
# that is the identity each machine compares against its own.
sub clock_machines {
	my $self = &signatorial_designer() || '';
	my @out;
	if (length $self) {
		push @out, { value => $self, label => &lang('me'), device => &clock_device(), me => 1 };
	}
	my %seen = ($self => 1);
	my $rows = eval { &db_query('select hostname, fqdn, signatorial, device from remote_machines order by hostname')->hashes } || [];
	foreach my $r (@{ $rows || [] }) {
		my $sig = $r->{'signatorial'} || '';
		next unless length $sig;
		next if $seen{$sig}++;
		# Android answers `hostname` with 'localhost', so a phone and a tablet
		# both look like the same machine. The fqdn still says which is which.
		my $label = &device_hostname_better($r->{'hostname'}, '', $r->{'fqdn'});
		$label =~ s/^\s+|\s+$//g;
		$label = &format_name($label) if length $label;
		$label = $sig unless length $label;
		push @out, { value => $sig, label => $label, device => ($r->{'device'} || ''), me => 0 };
	}
	return \@out;
}

# Does this alarm ring on this machine? An empty list is an alarm from before
# sharing: every machine that held the row rang it, so keep that reading.
sub clock_alarm_targets_me {
	my $alarm = shift;
	my $machines = $alarm->{'machines'};
	return 1 unless ref $machines eq 'ARRAY' && scalar @{$machines};
	my $self = &signatorial_designer() || '';
	return 0 unless length $self;
	return scalar grep { defined $_ && $_ eq $self } @{$machines};
}

sub clock_sounds {
	return [ @clock_sound_files ];
}

# The alarm picker's library: the short chimes first, then the long recordings.
sub clock_alarm_sounds {
	my @out;
	foreach my $s (@clock_sound_files) {
		my $label = $s;
		$label =~ s/\.mp3$//;
		$label = ucfirst $label;
		push @out, { value => 'notifications/' . $s, label => $label };
	}
	foreach my $s (sort { lc($clock_long_alarm_files{$a}) cmp lc($clock_long_alarm_files{$b}) } keys %clock_long_alarm_files) {
		push @out, { value => 'alarms/' . $s, label => $clock_long_alarm_files{$s} };
	}
	return \@out;
}

sub clock_sound_is_long {
	my $sound = shift;
	return 0 unless defined $sound && length $sound;
	return $sound =~ m{^alarms/} ? 1 : 0;
}

# A stored alarm may be a chime's bare name from before the library grew, a
# notifications/ path, or a long alarms/ path. Everything else is refused.
sub clock_valid_alarm_sound {
	my $sound = shift;
	return '' unless defined $sound && length $sound;
	$sound =~ s{^\./}{};
	$sound =~ s{^/}{};
	if ($sound =~ m{^(.*/)?([^/]+\.mp3)$}) {
		my $dir = $1 || '';
		my $base = $2;
		return 'alarms/' . $base if $dir eq 'alarms/' && exists $clock_long_alarm_files{$base};
		if (($dir eq 'notifications/' || $dir eq '') && grep { $_ eq $base } @clock_sound_files) {
			return 'notifications/' . $base;
		}
	}
	return '';
}

sub clock_valid_timer_sound {
	my $sound = shift;
	return 'notifications/chime.mp3' unless defined $sound && length $sound;
	$sound =~ s{^\./}{};
	$sound =~ s{^/}{};
	$sound =~ s{^notifications/}{};
	return 'notifications/' . $sound if grep { $_ eq $sound } @clock_sound_files;
	return 'notifications/chime.mp3';
}

sub clock_valid_sound {
	my $sound = shift;
	return '' unless defined $sound && length $sound;
	return (grep { $_ eq $sound } @clock_sound_files) ? $sound : '';
}

sub clock_sound_file {
	my $sound = shift;
	return './public/sounds/notifications/ring.mp3' unless defined $sound && length $sound;
	return './public/sounds/' . $sound;
}

sub clock_alarm_pidfile {
	my $uuid = shift || 'x';
	$uuid =~ s/[^A-Za-z0-9_\-]//g;
	my $dir = &home('~/.president');
	$dir = '/tmp' unless -d $dir;
	return $dir . '/clock_alarm_' . $uuid . '.pid';
}

# ---- the machine's own volume ------------------------------------------------
# A desktop alarm is played by sox on whatever sink the machine uses. The
# alarm's Volume is the loudness the person chose, so the sink itself is set for
# the ring and the level it was on is put back when the ring ends. The backend is
# discovered once; a machine with no mixer keeps the old sox scaling.
our $clock_volume_backend;

sub clock_volume_backend {
	return $clock_volume_backend if ref $clock_volume_backend eq 'HASH';
	my %bin;
	foreach my $cmd (qw(pactl wpctl amixer)) {
		my $path = `command -v $cmd 2>/dev/null`;
		chomp $path;
		$bin{$cmd} = $path if length $path;
	}
	my $found;
	if ($bin{'pactl'}) {
		my $info = `$bin{'pactl'} info 2>/dev/null`;
		$found = { kind => 'pactl', bin => $bin{'pactl'} } if $info =~ /Server Name:/;
	}
	if (!$found && $bin{'wpctl'}) {
		my $status = `$bin{'wpctl'} status 2>/dev/null`;
		$found = { kind => 'wpctl', bin => $bin{'wpctl'} } if $status =~ /PipeWire|Audio/;
	}
	if (!$found && $bin{'amixer'}) {
		foreach my $control (qw(Master PCM Speaker)) {
			my $out = `$bin{'amixer'} sget $control 2>/dev/null`;
			next unless $out =~ /\[(\d+)%\]/;
			$found = { kind => 'amixer', bin => $bin{'amixer'}, control => $control };
			last;
		}
	}
	$clock_volume_backend = $found if $found;
	return $found;
}

sub clock_system_volume_get {
	my $b = &clock_volume_backend();
	return undef unless $b;
	if ($b->{'kind'} eq 'pactl') {
		my $sink = '@DEFAULT_SINK@';
		my $out = `$b->{'bin'} get-sink-volume $sink 2>/dev/null`;
		return int($1) if $out =~ /(\d+)%/;
	}
	elsif ($b->{'kind'} eq 'wpctl') {
		my $sink = '@DEFAULT_AUDIO_SINK@';
		my $out = `$b->{'bin'} get-volume $sink 2>/dev/null`;
		return int(($1 * 100) + 0.5) if $out =~ /Volume:\s*([0-9.]+)/;
	}
	elsif ($b->{'kind'} eq 'amixer') {
		my $out = `$b->{'bin'} sget $b->{'control'} 2>/dev/null`;
		return int($1) if $out =~ /\[(\d+)%\]/;
	}
	return undef;
}

sub clock_system_volume_set {
	my $percent = shift;
	return 0 unless defined $percent && "$percent" =~ /^\d+$/;
	$percent = 5 if $percent < 5;
	$percent = 100 if $percent > 100;
	my $b = &clock_volume_backend();
	return 0 unless $b;
	my $rc;
	if ($b->{'kind'} eq 'pactl') {
		my $sink = '@DEFAULT_SINK@';
		$rc = system($b->{'bin'}, 'set-sink-volume', $sink, $percent . '%');
	}
	elsif ($b->{'kind'} eq 'wpctl') {
		my $sink = '@DEFAULT_AUDIO_SINK@';
		$rc = system($b->{'bin'}, 'set-volume', $sink, $percent . '%');
	}
	elsif ($b->{'kind'} eq 'amixer') {
		$rc = system($b->{'bin'}, 'sset', $b->{'control'}, $percent . '%');
	}
	else {
		return 0;
	}
	return $rc == 0 ? 1 : 0;
}

# ---- a tap's Volume for the whole house --------------------------------------
# A watch or deck tap that is out of its homebase's range reaches the house
# through a Pico relay. The message the manager receives is:
#   { type:"volume", to:"all"|"self"|<signatorial>, id:"<unique>",
#     data:{delta:N} | data:{volume:N} }
# Apply it on this machine and carry it to the peers that should hear the same
# tap. A peer that receives the forwarded copy (relayed => 1) applies it and
# does not fan it out again, so one tap cannot loop around the mesh. The unique
# id makes the Pico's bounded retry a no-op when the first copy did land; the
# claim is a cache row, not a lexical, because the BLE bridge and the HTTP rail
# are different workers and one tap may arrive on both.
sub volume_relay {
	my ($msg, $opts) = @_;
	$opts ||= {};
	$msg = {} unless ref $msg eq 'HASH';
	my $data = ref $msg->{'data'} eq 'HASH' ? $msg->{'data'} : $msg;
	my $target = $msg->{'to'} || $msg->{'target'} || 'self';
	$target = 'self' unless defined $target && length $target;
	my $id = $msg->{'id'} || '';
	my $result = { ok => 0, target => $target };
	# delta is read against the level the room is on now, before anything moves.
	# A machine with no mixer still has a house: it cannot resolve a delta, but
	# it can forward the delta itself for a peer with a sink to apply. The phone
	# was the watch's homebase and used to return "no mixer" before the fan-out,
	# so a Vol+ never reached the laptop's mixer.
	my $current = &clock_system_volume_get();
	my $delta;
	$delta = int($data->{'delta'}) if defined $data->{'delta'} && "$data->{'delta'}" =~ /^-?\d+$/;
	my $level;
	if (defined $data->{'volume'} && "$data->{'volume'}" =~ /^\d+$/) {
		$level = int($data->{'volume'});
	}
	elsif (defined $delta && defined $current) {
		$level = int($current) + $delta;
	}
	elsif (!defined $delta) {
		$result->{'error'} = 'no volume';
		return $result;
	}
	if (defined $level) {
		$level = 5 if $level < 5;
		$level = 100 if $level > 100;
		$result->{'volume'} = $level;
	}
	if (length $id) {
		my $now = &rightNow();
		eval {
			&db_query('insert or ignore into cache (uuid, context, app, server_time, timestamp, device) values (?,?,?,?,?,?)',
				$id, 'volume_relay', '__president', $now, $now, 'relay');
		};
		# changes() is 0 when the unique uuid was already claimed: the same tap
		# arrived again (the Pico retried, or the bridge and the relay both
		# heard it), so it must not move the sink a second time.
		my ($db) = &database_grabber();
		my $changes = $db ? eval { $db->dbh->selectrow_array('select changes()') } : undef;
		if (defined $changes && "$changes" eq '0') {
			$result->{'ok'} = 1;
			$result->{'duplicate'} = 1;
			return $result;
		}
	}
	my $me = &signatorial_designer() || '';
	my $named = ($target ne 'all' && $target ne 'self' && $target ne $me) ? $target : '';
	my $local = ($target eq 'all' || $target eq 'self' || ($me && $target eq $me)) ? 1 : 0;
	my $applied = 0;
	if ($local && defined $level) {
		$applied = &clock_system_volume_set($level) ? 1 : 0;
		$result->{'local'} = $applied;
	}
	my @peers;
	unless ($opts->{'relayed'}) {
		my $rms = $named
			? &remote_machine_lister({ signatorial => $named })
			: ($target eq 'all' ? &remote_machine_lister({ connection => 'active' }) : []);
		foreach my $rm ( @{ ref $rms eq 'ARRAY' ? $rms : [] } ) {
			next unless ref $rm eq 'HASH';
			my $sig = $rm->{'signatorial'} || '';
			next if !$sig || $sig eq $me;
			next unless $rm->{'manager'};
			push @peers, $rm;
		}
	}
	if (@peers) {
		my %form = (
			id => $id,
			target => $target,
			relayed => 'yes',
			signatorial => $me,
		);
		# A peer with a sink resolves its own level from the delta when this
		# machine could not (no mixer); otherwise every machine moves to the
		# level resolved here.
		if (defined $level) { $form{'volume'} = $level; }
		else { $form{'delta'} = $delta; }
		$result->{'forwarded'} = [ map { $_->{'signatorial'} } @peers ];
		# A tap waits on this response, so the fan-out is its own process: the
		# watch worker (one process on a phone) must not sit on a slow peer.
		eval {
			&subprocessor(sub {
				foreach my $rm (@peers) {
					eval {
						my $hop = &subs::remote_useragent_maker({ rm => $rm, signatorial => $rm->{'signatorial'} });
						next unless $hop && $hop->{'ua'} && $hop->{'manager'};
						$hop->{'ua'}->insecure(1)->connect_timeout(3)->inactivity_timeout(6)
							->post($hop->{'manager'} . '/manager/volume' => form => \%form)->result;
					};
				}
			}, { name => 'volume relay', warranty => '30s' });
		};
	}
	$result->{'ok'} = 1 if $applied || @peers;
	$result->{'error'} = 'no mixer' if $local && !$applied && !@peers;
	return $result;
}

sub clock_alarm_volume_file {
	my $uuid = shift || 'x';
	$uuid =~ s/[^A-Za-z0-9_\-]//g;
	my $dir = &home('~/.president');
	eval { File::Path::make_path($dir); } unless -d $dir;
	$dir = '/tmp' unless -d $dir;
	return $dir . '/clock_volume_' . $uuid . '.json';
}

# Set the machine's sink to the alarm's Volume and remember the level it was on.
# Returns 1 only when the ring can rely on the sink; a machine with no mixer
# returns 0 and the sox command keeps carrying the percentage.
sub clock_alarm_volume_raise {
	my $alarm = shift;
	return 0 unless ref $alarm eq 'HASH';
	my $uuid = $alarm->{'uuid'} || '';
	return 0 unless length $uuid;
	my $file = &clock_alarm_volume_file($uuid);
	if (-e $file) {
		# A previous ring for this alarm never put the level back (the app was
		# restarted mid-ring). Undo its raised level before saving this one.
		my $old = eval { decode_json(read_file($file)) };
		&clock_system_volume_set(int($old->{'volume'})) if ref $old eq 'HASH' && defined $old->{'volume'};
		unlink $file;
	}
	my $current = &clock_system_volume_get();
	return 0 unless defined $current;
	my $wanted = int($alarm->{'volume'} || 70);
	$wanted = 5 if $wanted < 5;
	$wanted = 100 if $wanted > 100;
	# Write the restore point first, so a failed set cannot leave a raised level
	# with nothing to put back.
	eval { write_file($file, encode_json({ volume => $current, wanted => $wanted, at => &rightNow() })); };
	return 0 unless -e $file;
	unless (&clock_system_volume_set($wanted)) {
		unlink $file;
		return 0;
	}
	return 1;
}

sub clock_alarm_volume_saved {
	my $uuid = shift;
	return 0 unless defined $uuid && length $uuid;
	return -e &clock_alarm_volume_file($uuid) ? 1 : 0;
}

sub clock_alarm_volume_restore {
	my $uuid = shift;
	return 0 unless defined $uuid && length $uuid;
	my $file = &clock_alarm_volume_file($uuid);
	return 0 unless -e $file;
	my $state = eval { decode_json(read_file($file)) };
	unlink $file;
	return 0 unless ref $state eq 'HASH' && defined $state->{'volume'};
	return &clock_system_volume_set(int($state->{'volume'}));
}

# A long-form track is one process; Dismiss kills it through the pid its shell
# wrote when it started. A short chime finishes on its own and has no pid file.
sub clock_alarm_stop_sound {
	my $uuid = shift;
	return 0 unless defined $uuid && length $uuid;
	my $restored = &clock_alarm_volume_restore($uuid);
	my $file = &clock_alarm_pidfile($uuid);
	return $restored unless -e $file;
	my $pid = eval { read_file($file) };
	unlink $file;
	return $restored unless defined $pid;
	$pid =~ s/\D//g;
	return $restored unless length $pid;
	# A stale pid file after a reboot must not kill whatever inherited the number.
	# The player's command line still names play and the sounds directory.
	if (-e '/proc/' . $pid . '/cmdline') {
		my $cmdline = eval { read_file('/proc/' . $pid . '/cmdline') } // '';
		return $restored unless $cmdline =~ /play/ && $cmdline =~ m{public/sounds};
	}
	else {
		return $restored;
	}
	eval { kill 'TERM', $pid; };
	eval { kill 'KILL', $pid; };
	return 1;
}

# A ringtone preview is the alarm's own sound, played on this machine for a
# few seconds while the person chooses. It is one process at a time, so
# auditioning the next sound ends the last one.
sub clock_preview_pidfile {
	my $dir = &home('~/.president');
	eval { File::Path::make_path($dir); } unless -d $dir;
	$dir = '/tmp' unless -d $dir;
	return $dir . '/clock_preview.pid';
}

sub clock_preview_stop {
	my $file = &clock_preview_pidfile();
	if (&device_setter() eq 'mobile') {
		&clock_device_broadcast(&app_action('JAWN_CLOCK_PREVIEW'), stop => 1);
	}
	return 0 unless -e $file;
	my $pid = eval { read_file($file) };
	unlink $file;
	return 0 unless defined $pid;
	$pid =~ s/\D//g;
	return 0 unless length $pid;
	return 0 unless -e '/proc/' . $pid;
	# The preview's timeout command line names the player and the sounds
	# directory; a recycled pid after a reboot does not.
	my $cmdline = eval { read_file('/proc/' . $pid . '/cmdline') } // '';
	return 0 unless $cmdline =~ /play/ && $cmdline =~ m{public/sounds};
	eval { kill 'TERM', $pid; };
	eval { kill 'KILL', $pid; };
	return 1;
}

sub clock_preview_play {
	my ($sound, $volume) = @_;
	$sound = &clock_valid_alarm_sound($sound) || 'notifications/ring.mp3';
	$volume = 70 unless defined $volume && "$volume" =~ /^\d+$/;
	$volume = 5 if $volume < 5;
	$volume = 100 if $volume > 100;
	&clock_preview_stop();
	if (&device_setter() eq 'mobile') {
		# The app plays it on the alarm channel, as it plays the ring itself.
		&clock_device_broadcast(&app_action('JAWN_CLOCK_PREVIEW'),
			uuid => 'preview',
			file => 'public/sounds/' . $sound,
			volume => $volume,
			ramp => 0,
			loop => 0,
			guard => 10000,
		);
		return 1;
	}
	my $file = &clock_sound_file($sound);
	my $level = sprintf('%.2f', $volume / 100);
	# timeout is the stop that a forgotten preview cannot outlive; the pid file
	# is what a second press, or another sound, uses to end it early.
	my $command = 'timeout 10 play -q -v ' . $level . ' ' . &quote($file) . ' fade t 1';
	my $pidfile = &clock_preview_pidfile();
	eval {
		&subprocessor(sub {
			system('sh', '-c', $command . ' & echo $! > ' . &quote($pidfile));
		}, { name => 'clock preview' });
	};
	return 1;
}

# The phone app is the only device that can wake itself from Doze and put an
# alarm in front of a locked screen. jawn hands it both the next alarm and the
# moment one rings over these short broadcasts; the app's receivers do the rest.
sub clock_device_broadcast {
	my ($action, %extra) = @_;
	return 0 unless &device_setter() eq 'mobile';
	my $command = 'am broadcast -a ' . $action;
	if (defined $extra{'at'} && "$extra{'at'}" =~ /^\d+$/ && $extra{'at'} > 0) {
		$command .= ' --el at ' . int($extra{'at'});
	}
	foreach my $key ( qw/uuid label app file play nfc_action reason/ ) {
		my $value = $extra{$key};
		next unless defined $value && length $value;
		$command .= ' --es ' . $key . ' ' . &quote($value);
	}
	foreach my $key ( qw/volume ramp loop guard snooze nfc stop/ ) {
		my $value = $extra{$key};
		next unless defined $value && "$value" =~ /^-?\d+$/;
		$command .= ' --ei ' . $key . ' ' . int($value);
	}
	eval {
		&subprocessor(sub { `$command`; }, { name => 'clock device broadcast' });
	};
	return 1;
}

1;
