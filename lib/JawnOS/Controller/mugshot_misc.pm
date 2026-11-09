package Manager;

# mugshot_misc: route actions moved out of Manager.pl, one sub per route so a
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

# GET /mugshot
sub action_9344 {
	my $c = shift;
	# public: the homepage shows the face to visitors, so it must not need a login
	my $dev = $c->param('device') || &subs::device_setter();
	my $name = &subs::setting_grabber({ app => 'me', setting => 'mugshot', device => $dev });
	unless (defined $name && $name =~ /^[\w.\-]+$/ && $name =~ /image|\.png|\.jpg|\.jpeg|\.webp|\.enc$/) { $c->rendered(404); return; }
	my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $dev });
	my $file = &subs::home($folder) . '/me/' . $name;
	unless (-e $file) { $c->rendered(404); return; }
	my $data;
	if ($file =~ /\.enc$/) {
		my $secret = &subs::suds_grabber();
		my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
		$data = &subs::openssl_file_read($standard, $secret, $file, 0, 1);
	} else {
		$data = eval { read_file($file) };
	}
	if (defined $data && length $data) {
		# the sealed file keeps no extension of its own, so read the image type
		# back off the bytes (a PNG name may hold a JPEG)
		my $type = $data =~ /^\x89PNG/ ? 'image/png'
			: $data =~ /^\xFF\xD8\xFF/ ? 'image/jpeg'
			: $data =~ /^GIF8/ ? 'image/gif'
			: $data =~ /^RIFF....WEBP/s ? 'image/webp'
			: 'application/octet-stream';
		$c->res->headers->content_type($type);
		$c->res->headers->cache_control('private, max-age=60');
		$c->render(data => $data);
	} else { $c->rendered(404); }
}

1;
