package Manager;

# pay_misc: route actions moved out of Manager.pl, one sub per route so a
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
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# ---- public payment pages --------------------------------------------------
# These carry no session: the customer is a stranger on the invoice link. The
# checkout start reads the invoice, the return reads the provider (never the
# browser's word), and a webhook verifies the provider's own signature.
# GET /pay/:provider/start
sub action_8568 {
	my $c = shift;
	my $provider = $c->stash('provider');
	my $uuid = $c->param('uuid') || '';
	my $cx = $c->param('cx') || '';
	my $out = &subs::pay_start($provider, $c, $uuid, $cx);
	if (!$out->{'ok'}) {
		my $back = (length $uuid && length $cx)
			? '/public_view/invoice/' . url_escape($uuid) . '/' . url_escape($cx)
			: '';
		return $c->render(
			template => 'pay/message', layout => 'public_view',
			title => 'Payment', message => ($out->{'error'} || 'That payment method is not available.'),
			back => $back,
		);
	}
	$c->redirect_to($out->{'url'});
}

# GET /pay/:provider/return
sub action_8586 {
	my $c = shift;
	my $provider = $c->stash('provider');
	my $out = &subs::pay_return_handle($provider, $c);
	my $message = $out->{'message'} || '';
	if ($out->{'ok'}) {
		if ($out->{'duplicate'}) {
			$message = 'This payment was already recorded.';
		}
		elsif (defined $out->{'balance'} && $out->{'balance'} <= 0) {
			$message = 'Payment received in full. Thank you.';
		}
		elsif (defined $out->{'balance'}) {
			$message = 'Payment received. The invoice balance is now ' . &subs::price_formatter($out->{'balance'}) . '.';
		}
		else {
			$message = 'Payment received. Thank you.';
		}
	}
	$c->render(
		template => 'pay/return', layout => 'public_view',
		ok => $out->{'ok'} ? 1 : 0,
		pending => $out->{'pending'} ? 1 : 0,
		message => $message,
		provider => $provider,
		invoice_url => ($out->{'invoice_url'} || ''),
	);
}

# ANY /pay/:provider/webhook
sub action_8614 {
	my $c = shift;
	my $provider = $c->stash('provider');
	my $body = $c->req->body // '';
	my $out;
	if ($provider eq 'stripe') {
		my $sig = $c->req->headers->header('Stripe-Signature') || '';
		unless (&subs::pay_stripe_signature_ok($body, $sig)) {
			return $c->render(status => 400, json => { ok => 0, error => 'bad signature' });
		}
		my $event = eval { decode_json($body) } || {};
		$out = &subs::pay_stripe_webhook($event);
	}
	elsif ($provider eq 'square') {
		my $sig = $c->req->headers->header('x-square-hmacsha256-signature') || '';
		my $url = &subs::pay_setting('square_webhook_url', '') || &subs::pay_webhook_url($c, 'square');
		unless (&subs::pay_square_signature_ok($body, $sig, $url)) {
			return $c->render(status => 400, json => { ok => 0, error => 'bad signature' });
		}
		my $event = eval { decode_json($body) } || {};
		$out = &subs::pay_square_webhook($event);
	}
	elsif ($provider eq 'paypal') {
		my $event = eval { decode_json($body) } || {};
		my %h;
		foreach my $k ( qw/paypal-auth-algo paypal-cert-url paypal-transmission-id paypal-transmission-sig paypal-transmission-time/ ) {
			$h{$k} = $c->req->headers->header($k) || '';
		}
		my $verified = &subs::pay_paypal_webhook_verify($event, \%h);
		$out = &subs::pay_paypal_webhook($event, $verified);
	}
	else {
		return $c->render(status => 404, json => { ok => 0, error => 'unknown payment method' });
	}
	$c->render(
		status => ($out->{'ok'} ? 200 : 400),
		json => {
			ok => $out->{'ok'} ? 1 : 0,
			error => $out->{'error'},
			ignored => $out->{'ignored'},
			duplicate => $out->{'duplicate'},
		},
	);
}

# A bank or payment service that can see e-Transfer notifications posts the
# facts here. The task token is the gate, like the LoRaWAN uplink's.
# POST /pay/interac/hook
sub action_8660 {
	my $c = shift;
	my $token = $c->param('token') || '';
	my $body = eval { $c->req->json } || {};
	$body = {} unless ref $body eq 'HASH';
	if (!scalar keys %{$body}) {
		foreach my $k ( qw/amount currency sender reference memo message invoice email deposited pending text/ ) {
			my $v = $c->param($k);
			$body->{$k} = $v if defined $v;
		}
	}
	my $out = &subs::pay_interac_hook($body, $token, $c);
	$c->render(
		status => ($out->{'ok'} ? 200 : 403),
		json => {
			ok => $out->{'ok'} ? 1 : 0,
			error => $out->{'error'},
			staged => $out->{'staged'},
			recorded => $out->{'recorded'},
		},
	);
}

1;
