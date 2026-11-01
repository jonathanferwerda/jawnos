package Manager;

# manager_people2: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/people/crest/vouch
sub action_24511 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'citizen only' }) unless &people_citizen($c);
	my $uuid = $c->param('uuid') || '';
	my $peer = &subs::crest_peer_find($uuid);
	return $c->render(json => { ok => 0, error => 'no such crest' }) unless $peer && ref $peer->{'crest'} eq 'HASH';
	my $own = &subs::crest_record_read();
	return $c->render(json => { ok => 0, error => 'this house has no crest yet' }) unless $own->{'uuid'} && $own->{'pubkey'};
	my $suds = &subs::session_suds($c);
	my $priv = &subs::crest_key_read($suds);
	return $c->render(json => { ok => 0, error => 'the crest key is not available' }) unless $priv;
	my $vouch = {
		from_uuid => $own->{'uuid'},
		from_pubkey => $own->{'pubkey'},
		from_name => $own->{'name'} || '',
		to_uuid => $peer->{'crest'}->{'uuid'} || '',
		to_pubkey => $peer->{'crest'}->{'pubkey'} || '',
		to_name => $peer->{'crest'}->{'name'} || '',
		method => 'in person',
		scope => 'communication',
		at => &subs::rightNow(),
	};
	return $c->render(json => { ok => 0, error => 'the other crest has no key' }) unless length $vouch->{'to_pubkey'};
	my $signed = &subs::crest_vouch_sign($vouch, $priv);
	return $c->render(json => { ok => 0, error => 'the vouch could not be signed' }) unless $signed;
	my $updated = &subs::crest_peer_update($uuid, { vouch => $signed, status => 'met', met_at => $signed->{'at'} });
	return $c->render(json => { ok => 0, error => 'the vouch could not be stored' }) unless $updated;
	return $c->render(json => { ok => 1, vouch => $signed });
}

# POST /manager/people/house_name
sub action_24540 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'citizen only' }) unless &people_citizen($c);
	my $name = $c->param('name') // '';
	$name =~ s/^\s+|\s+$//g;
	$name = substr($name, 0, 120);
	return $c->render(json => { ok => 0, error => 'a name is needed' }) unless length $name;
	my $record = &subs::crest_record_read();
	if ($record->{'uuid'}) {
		my $suds = &subs::session_suds($c);
		my $priv = &subs::crest_key_read($suds);
		return $c->render(json => { ok => 0, error => 'the crest key is not available' }) unless $priv;
		$record->{'name'} = $name;
		$record->{'version'} = ($record->{'version'} || 0) + 1;
		$record->{'server_time'} = &subs::rightNow();
		my $signed = &subs::crest_sign_record($record, $priv);
		return $c->render(json => { ok => 0, error => 'the crest could not be signed' }) unless $signed;
		return $c->render(json => { ok => 0, error => 'the crest could not be saved' }) unless &subs::crest_record_write($signed);
	}
	else {
		&subs::setting_setter({ app => '__president', setting => 'house_name', device => 'all', value => $name });
	}
	return $c->render(json => { ok => 1, name => $name });
}

# GET /manager/people/crest_image
sub action_24564 {
	my $c = shift;
	unless (&people_citizen($c)) { $c->rendered(403); return; }
	my $peer_uuid = $c->param('peer') || '';
	my $app = $c->param('app') || '';
	my ($file, $device);
	if ($peer_uuid) {
		my $entry = &subs::crest_peer_find($peer_uuid);
		unless ($entry) { $c->rendered(404); return; }
		$file = &subs::crest_peer_image_file($entry);
		$device = $entry->{'device'} || &subs::device_setter();
	}
	elsif ($app) {
		my $record = &subs::construct_crest_record_read($app);
		unless ($record->{'uuid'}) { $c->rendered(404); return; }
		&subs::construct_crest_image_materialize($c, $app);
		my $kind = (($c->param('kind') || '') eq 'reference') ? 'reference' : 'image';
		$file = &subs::crest_image_file($record, $kind);
		$device = $record->{'device'} || &subs::device_setter();
	}
	else {
		my $record = &subs::crest_record_read();
		my $kind = (($c->param('kind') || '') eq 'reference') ? 'reference' : 'image';
		$file = &subs::crest_image_file($record, $kind);
		$device = $record->{'device'} || &subs::device_setter();
	}
	unless ($file) { $c->rendered(404); return; }
	my $suds = &subs::session_suds($c);
	unless ($suds) { $c->rendered(403); return; }
	my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard', device => $device }) || 'aes-256-ctr';
	my $data = &subs::openssl_file_read($standard, $suds, $file, 0, 1);
	unless (defined $data && length $data) { $c->rendered(404); return; }
	my $type = $data =~ /^\x89PNG/ ? 'image/png'
		: $data =~ /^\xFF\xD8\xFF/ ? 'image/jpeg'
		: 'application/octet-stream';
	$c->res->headers->content_type($type);
	$c->res->headers->cache_control('private, max-age=60');
	$c->render(data => $data);
}

1;
