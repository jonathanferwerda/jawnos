package Manager;

# embedded_misc: route actions moved out of Manager.pl, one sub per route so a
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

# A teletype (the deck) pulls the house's running database, sealed, onto its own
# SD card. The Dev panel's Backup button hands the deck the snapshot's names and
# the deck fetches the bytes here, so this serves the rolling
# database/backups/jawnos.enc - the house as it stands. If that snapshot is older
# than the utility controller's own backup interval it is taken fresh first, so the
# deck gets a current copy without waiting for the hourly job. A device has no
# session, so this route rides the gate-exempt rail and identifies its caller
# itself: the chip_id must be a device this machine holds, the same identification
# every other embedded request carries (hardened in a later pass).
# GET /embedded/teletype/backup
sub action_9845 {
	my $c = shift;
	# The deck has no browser session; it proves itself with the rotated Now Me
	# pair exactly as its other routes do. A chip id alone is public, so it is
	# no longer sufficient to hand out the encrypted vault.
	unless (&subs::embedded_authorizer($c)) {
		return $c->rendered(403);
	}
	my $chip_id = $c->param('chip_id');
	my $known;
	if ($chip_id) {
		foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
			next unless $d->{'chip_ids'};
			foreach my $ch ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
				if ($ch->{'id'} && $ch->{'id'} eq $chip_id) { $known = 1; last; }
			}
			last if $known;
		}
	}
	unless ($known) { $c->rendered(403); return; }
	my $enc = &subs::backups_dir() . '/jawnos.enc';
	my $interval = 3600;   # the utility controller's backups job, by default hourly
	my $uc = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) } || {};
	foreach my $job ( values %{$uc} ) {
		next unless ref $job eq 'HASH' && ref $job->{'backups'} eq 'HASH';
		$interval = 0 + $job->{'backups'}->{'interval'} if $job->{'backups'}->{'interval'};
	}
	my $age = -f $enc ? (time() - (stat $enc)[9]) : 1e9;
	if ($age > $interval) {
		my $cc = &subs::controller_builder();
		$cc->param('reason' => 'teletype_backup');
		eval { &subs::backup_now($cc); };
	}
	unless (-f $enc) { $c->rendered(404); return; }
	$c->res->headers->content_type('application/octet-stream');
	$c->res->content->asset(Mojo::Asset::File->new(path => $enc));
	$c->rendered(200);
}

1;
