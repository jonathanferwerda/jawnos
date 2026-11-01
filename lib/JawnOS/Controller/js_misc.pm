package Manager;

# js_misc: route actions moved out of Manager.pl, one sub per route so a
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

# GET /js/manager/bundle.js
sub action_7407 {
	my $c = shift;
	my $dir = 'public';
	my $sig = '';
	my @bundle;
	foreach my $rel (@manager_bundle_files) {
		# An app's index file may carry a folder of parts beside it; the
		# helper returns the index first, then the parts in name order.
		my @files = &subs::js_part_files($dir . $rel);
		push @bundle, @files;
		foreach my $file (@files) {
			my @st = stat($file);
			$sig .= $file . ':' . ($st[9] // 0) . ':' . ($st[7] // 0) . ';';
		}
	}
	my $etag = '"' . &subs::md5_sum($sig) . '"';
	$c->res->headers->etag($etag);
	$c->res->headers->cache_control('no-cache, max-age=0, must-revalidate');
	$c->res->headers->content_type('application/javascript');
	if (($c->req->headers->if_none_match // '') =~ /\Q$etag\E/) {
		$c->res->code(304);
		$c->res->body('');
		return $c->rendered(304);
	}
	unless ($manager_bundle_cache && $manager_bundle_cache->[0] eq $sig) {
		my ($path, $sigpath) = manager_bundle_paths();
		my $stored = '';
		if (-s $path && -s $sigpath) {
			my $stamp = eval { read_file($sigpath) } // '';
			$stamp =~ s/\s+\z//;
			$stored = eval { read_file($path) } // '' if $stamp eq $sig;
		}
		if (length $stored) {
			$manager_bundle_cache = [$sig, $stored];
		}
		else {
			my $raw = '';
			foreach my $file (@bundle) {
				my $src = eval { read_file($file) } // '';
				(my $label = $file) =~ s{^public}{};
				$raw .= "\n;/* $label */\n" . $src . "\n;\n";
			}
			my $built = js_minify($raw);
			# Payload first, signature last, so a reader that matches the signature
			# is guaranteed the matching payload. A lost race just rebuilds.
			eval {
				my $tmp = "$path.$$" . '.tmp';
				write_file($tmp, $built);
				rename($tmp, $path) or die "rename $tmp: $!";
				write_file($sigpath, $sig . "\n");
			};
			$manager_bundle_cache = [$sig, $built];
		}
	}
	$c->res->body($manager_bundle_cache->[1]);
	return $c->rendered(200);
}

1;
