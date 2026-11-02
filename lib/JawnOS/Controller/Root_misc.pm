package Manager;

# Root_misc: route actions moved out of Manager.pl, one sub per route so a
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

# GET /
sub action_2998 {
	my $c = shift;
	my $homepage;
	my $user_agent = $c->req->headers->user_agent;
	my $remote_signatorial = $c->param('signatorial');
	my $signatorial = &subs::signatorial_designer();
	if ($c->param('signatorial')) {
		my $rs = &subs::decrypter(&subs::shorthand_name(&subs::rightNow(), 5) . &subs::shorthand_name($signatorial, 5), $remote_signatorial);

		if ($rs eq $signatorial) {
			$homepage = $signatorial;
		} else {
			$homepage = 'dunno';
		}
	} else {
		$homepage = &homepage_maker($c);
	}
	$c->render('text' => $homepage);
}

# GET /house/logo.png
# The house's mark as its own small response. Every full page used to inline the
# stored data: URI as a favicon, which put ~195 KB of base64 into every document
# (and made a 265 KB page); the browser now fetches it once and revalidates with
# the ETag. A house with no uploaded mark gets the shipped drawing, so the URL
# always answers and no page has to ask first.
sub action_2999 {
	my $c = shift;
	my $parts = &subs::data_uri_parts(&subs::logo_data_uri());
	my $bytes = $parts ? $parts->{'bytes'} : eval { read_file('public/images/make believe/Pillow.png', binmode => ':raw') };
	unless (defined $bytes && length $bytes) {
		$c->res->code(404);
		$c->render(text => '');
		return;
	}
	$c->res->headers->content_type($parts ? $parts->{'mime'} : 'image/png');
	my $etag = '"' . md5_sum($bytes) . '"';
	my $if_none_match = $c->req->headers->if_none_match;
	if (defined $if_none_match && index($if_none_match, $etag) >= 0) {
		$c->res->code(304);
		$c->res->headers->etag($etag);
		$c->res->body('');
		return;
	}
	$c->res->headers->etag($etag);
	# The mark changes only when the house uploads a new one. Let the browser keep
	# it for a day, then revalidate to a 304 rather than re-sending the image.
	$c->res->headers->cache_control('public, max-age=86400, must-revalidate');
	$c->res->body($bytes);
}

# POST manager/ws/remote_control
sub action_47831 {
	my $c = shift;
	my $destination = $c->param('destination');
	my $value = $c->param('value');
	my $app = &subs::unformat_name($c->param('app'));
	my $control = $c->param('control');
	&Websocket::send($app, {
		value => $value,
		app => $app,
		control => $control,
		destination => $destination,
		type => 'remote_control'
	});
	$c->render(text => 'ok');

}

1;
