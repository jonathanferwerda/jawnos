package Manager;

# mail_misc: route actions moved out of Manager.pl, one sub per route so a
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

# GET /mail/homepage_form
sub action_32633 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	$c->render('text' => &mail_checker($c)->{'contents'} ,timestamp => $timestamp	);
}

# POST /mail/msg
sub action_45946 {
	my $c = shift;
	my $msg = {};

	$msg = eval { return decode_json $c->param('msg') } || {};
	# a hand-over from the mesh must come from the mesh: a signatorial this
	# house knows, a live session, or the machine itself. Without one this is an
	# open insert into the mailbox - the one door that must stay shut, since a
	# message nobody sent is exactly what "not written down" promises against
	my $signatorial = $c->param('signatorial');
	my $local_door = $c->tx->remote_address eq $c->tx->local_address;
	my $known_neighbour = $signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0];
	my $approved = ($c->session('authentication') || '') eq 'approved';
	# A hand-over that names a neighbour must be signed by that neighbour's pinned
	# key: a signatorial is a name, and a name alone once let anyone insert a
	# letter into this mailbox. A signed peer is then held to its lease: a reply
	# to a thread this house already holds needs visitor; a conversation it starts
	# needs resident.
	my $signed_peer = 0;
	if (!$local_door && $known_neighbour && $known_neighbour->{'pubkey'}) {
		$signed_peer = &subs::peer_verify($c, $known_neighbour) ? 1 : 0;
		unless ($signed_peer) {
			$log->info('mail hand-over refused: ' . $signatorial . ' did not sign');
			$c->render(json => { ok => 0, error => 'not signed' });
			return;
		}
	}
	unless ($local_door || $signed_peer || ($approved && !$known_neighbour)) {
		$log->info('mail hand-over refused from ' . $c->tx->remote_address . ' signatorial=' . ($signatorial || 'none'));
		$c->render(json => { ok => 0, error => 'unknown neighbour' });
		return;
	}
	if ($signed_peer) {
		my $thread = $msg->{'conversation_uuid'} || '';
		my $is_reply = 0;
		if ($thread ne '') {
			$is_reply = 1 if &subs::db_query('select 1 from mailbox where conversation_uuid = ? limit 1', $thread)->hashes->[0];
		}
		if (!$is_reply && ($msg->{'in_reply_to'} || '') ne '') {
			$is_reply = 1 if &subs::db_query('select 1 from mailbox where message_id = ? limit 1', $msg->{'in_reply_to'})->hashes->[0];
		}
		my $need = &subs::peer_action_scope($is_reply ? 'mail_reply' : 'mail_start') || 'resident';
		unless (&subs::peer_allows($c, $known_neighbour, $need)) {
			$log->info('mail hand-over refused: ' . $signatorial . ' holds no ' . $need . ' grant');
			$c->render(json => { ok => 0, error => 'not permitted' });
			return;
		}
		unless (&subs::peer_rate_ok($known_neighbour, 'message')) {
			$log->info('mail hand-over rate limited: ' . $signatorial);
			$c->render(json => { ok => 0, error => 'rate limited' }, status => 429);
			return;
		}
	}
	if ($msg->{'uuid'}) {
		# an ephemeral letter is only ever heard live: the machine that catches
		# it delivers it to whoever is tuned in and writes nothing down
		if ($msg->{'ephemeral'}) {
			$msg->{'decrypted'} = 'yes';
			$msg->{'envelope'} = $c->render_to_string(
				template => 'mail/message',
				'm' => $msg,
				'me' => ''
			);
			&mailws_sender($msg);
			$c->render(json => $msg);
			return;
		}
		my $pre_msg = &subs::db_query('select uuid from mailbox where uuid=? and manager_file=?', $msg->{'uuid'}, $msg->{'manager_file'})->hashes->[0];
		unless ($pre_msg->{'uuid'}) {
			&subs::db_insert('mailbox', $msg);
			# a neighbour handed a message over: the browsers hear about it
			# here, not only on the machine the letter started from
			&subs::mail_arrival({ c => $c, %{$msg} });
			my $remote_machines = &subs::db_select('remote_machines', undef, { connection => 'active' })->hashes;
			my $form_data = {
				signatorial => &subs::signatorial_designer(),
				msg => encode_json $msg
			};
			foreach my $rm ( @{$remote_machines} ) {
				&subs::subprocessor(sub {
			    Mojo::IOLoop->reset;
					$rm = &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
					my $url = $rm->{'manager'} . '/mail/msg';
					my $res = $rm->{'ua'}->post($url => form => $form_data)->result;
					if ($res->is_success) {

					}
				}, { name => 'embedded mail msg' });
			}
		}
	}

	$c->render(json => $msg);
}

1;
