package Manager;

# manager_misc3: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/vault_share
sub action_9883 {
	my $c = shift;
	# A linked machine with no key of its own asks for the house key. The request
	# must carry its peer signature and a key already pinned on file - no
	# trust-on-first-contact here, since this hands out the key itself - and the
	# reply is sealed to a one-time secret the asker supplied. Turning off the
	# __president/vault_share setting refuses everyone. The route is exempt from
	# the gate (a keyless machine has no session); peer_verify is its gate.
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $share = &subs::setting_grabber({ app => '__president', setting => 'vault_share' });
	$share = 'yes' unless defined $share && length $share;
	unless ($share eq 'yes') { $c->render(json => { ok => 0, error => 'sharing off' }); return; }
	# the key this machine holds: the vault first, and a worker that resolved it
	# before its vault row went missing still knows it (suds_grabber falls back)
	my $suds = eval { &subs::suds_grabber() };
	$suds ||= ( &subs::vault_read() )[0];
	my $seal = $c->param('seal');
	unless ($suds && $seal && $seal =~ /^[0-9A-Za-z-]{20,80}$/) { $c->render(json => { ok => 0 }); return; }
	my $sealed = &subs::note_encrypter($seal, $suds);
	unless ($sealed) { $c->render(json => { ok => 0 }); return; }
	$c->render(json => { ok => 1, sealed => $sealed });
}

# GET /manager/legacy_reseal
sub action_9907 {
	my $c = shift;
	# A linked machine asks this one to upgrade its values left from the era when
	# the outer layer was sealed with the empty passphrase (public knowledge, so
	# such values are effectively plaintext at rest). Nothing secret crosses: the
	# work is local and idempotent, and peer_verify against a pinned key is the
	# gate, like vault_share.
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $result = eval { &subs::legacy_reseal() } || { ok => 0 };
	$c->render(json => { %{$result}, by => &subs::signatorial_designer() });
}

# POST /manager/key_push
sub action_9920 {
	my $c = shift;
	# A linked machine that has just rotated the house key hands the new one
	# over: the request carries its pinned signature and the new key wrapped
	# under the key it replaced, so only a machine still on that key can read it
	# - a machine on a different lineage fails the unwrap and keeps its own. The
	# adoption is the same worker the local rotation runs (generate replaced by
	# adopt), and this machine's own sealed files go to its queue.
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $K = eval { &subs::suds_grabber() };
	my $proved = $c->param('proved');
	unless ($K && $proved) { $c->render(json => { ok => 0, error => 'no key here' }); return; }
	my $Knew = &subs::crypt_simple_unwrap($K, $proved);
	unless (defined $Knew && length $Knew) { $c->render(json => { ok => 0, error => 'not for this key' }); return; }
	$Knew =~ s/\s+$//;
	if ($Knew eq $K) { $c->render(json => { ok => 1, already => 1 }); return; }
	my $result = &subs::rotate_house_key($Knew);
	if ($result->{'ok'}) {
		eval { &subs::minion_grabber()->enqueue('folders_reseal' => [ { before => $result->{'at'}, budget => 600 } ] => { attempts => 2 }) };
	}
	$c->render(json => { ok => $result->{'ok'} ? 1 : 0, error => $result->{'error'}, summary => { settings => $result->{'settings'}, security => $result->{'security'}, links => $result->{'links'} } });
}

# POST /manager/operator_door
sub action_9944 {
	my $c = shift;
	# A Now Me rotation is pushed over the signed rail to every linked machine.
	# The device probes a fallback House with this pair, so a peer that has not
	# run a settings sync yet (or whose session cookie lapsed) must still be able
	# to store it. peer_verify is the gate; the value is the row Now Me wrote.
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $value = $c->param('value');
	unless ($edt && $chip_id && defined $value && length $value) {
		$c->render(json => { ok => 0, error => 'missing device or value' });
		return;
	}
	# Store the writer's server_time, so every machine holds the same revision
	# of the row and a later sync does not flip between copies.
	my $server_time = $c->param('server_time') || &subs::rightNow();
	&subs::setting_setter({
		app => $edt,
		setting => 'operator_door',
		subsetting => $chip_id,
		device => ($c->param('device') || &subs::device_setter()),
		value => $value,
		server_time => $server_time,
		timestamp => $server_time,
	});
	$c->render(json => { ok => 1 });
}

# The peer half of remote_deploy: pull, reinstall the desktop app and restart,
# authorized by the caller's signatorial - deploys over http now, no ssh.
# POST /manager/self_deploy
sub action_10187 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $repo = &subs::home('~/jawnos');
	# force reconciles a tree git cannot fast-forward (the branch's history was
	# rewritten, or local commits exist) by resetting hard to this machine's
	# update branch; off by default so a plain pull never clobbers real work.
	my ($status, $out) = &subs::git_repo_update({ repo => $repo, force => ($c->param('force') ? 1 : 0),
		branch => &subs::sync_update_branch_get() });
	if (-d &subs::home('~/.local/share/jawnos/desktop') && -x "$repo/desktop/install.sh") {
		`cd "$repo" && ./desktop/install.sh >/dev/null 2>&1`;
	}
	&subs::install_extras();
	$log->info('self_deploy from ' . ($signatorial || '?') . ': ' . ($status || '?') . ($c->param('force') ? ' (force)' : '')) if $log;
	&subs::restart_request('self_deploy from ' . ($signatorial || 'a peer') . ': ' . ($status || '?'));
	$c->render(text => "deployed $status\n" . ($out || ''));
}

# A peer's code as a git bundle: the other half of "whoever has the newest is
# it". The caller sends the commit it holds, and the bundle carries only what is
# new since then when this tree knows it (a fast delta), else the whole history.
# Gated by the signatorial the way the app_release routes are.
# GET /manager/code_bundle
sub action_10288 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $repo = &subs::home('~/jawnos');
	my $git = &subs::git_binary();
	my $base = $c->param('base') || '';
	require File::Temp;
	my ($fh, $path) = File::Temp::tempfile(SUFFIX => '.bundle', UNLINK => 1);
	close $fh;
	my $delta = '';
	if ($base =~ /^[0-9a-f]{7,40}$/ && system("cd \"$repo\" && \"$git\" cat-file -e $base 2>/dev/null") == 0) {
		$delta = " ^$base";
	}
	`cd "$repo" && "$git" bundle create "$path" HEAD$delta 2>&1`;
	my $data = '';
	if (open(my $bf, '<', $path)) { binmode $bf; local $/; $data = <$bf>; close $bf; }
	unlink $path;
	unless (length $data) { $c->rendered(500); return; }
	$c->res->headers->content_type('application/octet-stream');
	$c->render(data => $data);
}

# GET /manager/app_release
sub action_10311 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	# The signatorial is public (it is rendered into DOM attributes), so naming
	# one is not a credential: the request must carry the machine's signature.
	# app_release_sync signs every call through peer_useragent.
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $hostname = `hostname`; chomp $hostname;
	$c->render(json => { hostname => $hostname, signatorial => &subs::signatorial_designer(), releases => &app_release_lister() });
}

# GET /manager/app_download
sub action_10322 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $product = $c->param('product') || 'app';
	my $want = $c->param('versionCode');
	my $pick;
	foreach my $r ( @{ &app_release_lister() } ) {
		next unless $r->{'product'} eq $product;
		next if defined $want && $want ne '' && $r->{'versionCode'} != $want;
		$pick = $r if !$pick || $r->{'versionCode'} > $pick->{'versionCode'};
	}
	unless ($pick) { $c->rendered(404); return; }
	$c->res->headers->content_type('application/vnd.android.package-archive');
	$c->res->headers->content_disposition('attachment; filename="' . $pick->{'filename'} . '"');
	$c->res->content->asset(Mojo::Asset::File->new(path => &subs::releases_dir() . '/' . $pick->{'filename'}));
	$c->rendered(200);
}

# Trigger a fresh app-release pull on demand: the mobile app's "Update app"
# button calls this so a stale 5-minute sync doesn't report "up to date". The
# pull runs in a forked child (a slow peer or a 35 MB download must not block
# the event loop); the caller re-scans the releases dir afterwards.
# POST /manager/app_release_sync
sub action_10345 {
	my $c = shift;
	unless (($c->session('authentication') || '') eq 'approved') {
		$c->rendered(403);
		return;
	}
	# A release sync asks every peer (a 20s inactivity timeout each) and may copy
	# a 32MB APK. Inline it held the request worker for minutes with one socket
	# per peer - the phone's "one worker at 100%" with no job to blame. The route
	# already answers `syncing`, so the work was always meant to be a child.
	&subs::subprocessor(sub {
		eval { &subs::app_release_sync(); };
	}, { name => 'app release sync (on demand)', fork => 1 });
	$c->render(json => { ok => 1, syncing => 1 });
}

# The local Ollama's model list, for a peer that offers (and routes to) this
# machine's models - the app-release rail, with the same signatorial gate.
# GET /manager/ollama_models
sub action_10358 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm) { $c->rendered(403); return; }
	my $ua = Mojo::UserAgent->new(connect_timeout => 3, inactivity_timeout => 8, request_timeout => 12);
	my $res = eval { $ua->get('http://localhost:11434/api/tags')->result };
	my $models = [];
	if ($res && $res->is_success) {
		my $b = eval { $res->json } || {};
		$models = $b->{'models'} if ref $b->{'models'} eq 'ARRAY';
	}
	my $hn = `hostname`; chomp $hn;
	$c->render(json => { hostname => $hn, models => $models });
}

# A peer's chat turn, run against this machine's Ollama. The caller already
# decided the model lives here; this only carries the call and its answer back.
# The local model may take minutes, so the request is non-blocking: this worker
# waits on the user agent's promise instead of its call stack, and keeps serving
# every other request meanwhile.
# POST /manager/ollama_chat
sub action_10378 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm) { $c->rendered(403); return; }
	my $payload = eval { $c->req->json } || {};
	my $ua = Mojo::UserAgent->new(connect_timeout => 5, inactivity_timeout => 300, request_timeout => 600);
	$c->stash('ollama_ua' => $ua);
	$c->render_later;
	&subs::request_busy_release($c);
	$ua->post_p('http://localhost:11434/api/chat' => json => $payload)->then(sub {
		my $res = shift;
		unless ($res && $res->is_success) {
			$c->render(json => { error => 'the local Ollama did not answer' });
			return;
		}
		$c->res->headers->content_type('application/json');
		$c->render(data => $res->body);
	})->catch(sub {
		$c->render(json => { error => 'the local Ollama did not answer' });
	});
}

# ---------------------------------------------------------------------------
# The Crew: what each machine can do and where a job runs. crew.pl owns the
# ability registry and the job kinds; these routes carry it between machines.
# state and job are peer routes - the same roster check as app_download - and
# the job route also verifies the signature, because it executes work. A kind
# must be in crew::job_kind's registry; nothing here accepts a command, a path
# or a sub name from the caller.
# ---------------------------------------------------------------------------
# GET /manager/crew/state
sub action_10408 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm) { $c->rendered(403); return; }
	$c->render(json => &crew::state());
}

# POST /manager/crew/job
sub action_10415 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	# A job payload is bounded: a peer is trusted, but a 4 GB prompt must not be
	# read into a worker's memory before the kind is even looked at.
	my $declared = $c->req->headers->content_length || 0;
	if ($declared > 64 * 1024 * 1024) {
		$log->info('crew job refused: ' . $declared . ' bytes from ' . ($signatorial || '?'));
		$c->render(status => 413, json => { ok => 0, error => 'the payload is too large' });
		return;
	}
	my $body = eval { $c->req->json } || {};
	$body = {} unless ref $body eq 'HASH';
	my $kind = defined $body->{'kind'} ? $body->{'kind'} : '';
	my $spec = &crew::job_kind($kind);
	unless ($spec) {
		$log->info('crew job refused: unknown kind "' . substr($kind, 0, 60) . '" from ' . ($signatorial || '?'));
		$c->render(status => 400, json => { ok => 0, error => 'unknown job kind' });
		return;
	}
	my $payload = ref $body->{'payload'} eq 'HASH' ? $body->{'payload'} : {};
	my $origin = defined $body->{'origin'} ? $body->{'origin'} : '';
	# A guarded origin is what keeps a job from bouncing between two machines.
	$origin =~ s/[^0-9a-zA-Z]//g;
	my $job_id = defined $body->{'job_id'} ? $body->{'job_id'} : '';
	$job_id =~ s/[^A-Za-z0-9_.-]//g;
	$job_id = substr($job_id, 0, 80);
	$job_id = &crew::new_job_id($kind) unless length $job_id;
	# The same job_id that already ran successfully answers from the cache, so a
	# retried request does not run the work twice.
	my $cached = &crew::job_cached($job_id);
	if ($cached) {
		$log->info('crew job ' . $kind . ' ' . $job_id . ' answered from the cache');
		$c->render(json => $cached);
		return;
	}
	$log->info('crew job accepted: ' . $kind . ' ' . $job_id . ' from ' . ($origin || 'this machine'));
	&crew::queue_note($job_id, $kind, $origin);
	# The work runs in a forked child (the same pattern as the AI routes here),
	# so a model call or a transcription cannot hold this worker's event loop.
	&subs::render_in_subprocess($c, sub {
		return &crew::job_run($kind, $payload,
			timeout => $spec->{'timeout'},
			job_id  => $job_id,
			origin  => $origin,
		);
	}, sub {
		my ($c, $result) = @_;
		$result ||= { ok => 0, error => 'the job did not finish' };
		&crew::queue_done($job_id);
		&crew::job_store($job_id, $result) if $result->{'ok'};
		$log->info('crew job ' . $kind . ' ' . $job_id . ($result->{'ok'}
			? ' done'
			: ' failed: ' . substr($result->{'error'} || 'no reason', 0, 160)));
		$c->render(json => $result);
	});
}

# The Configure panel's "Advertise now": refresh this machine's own facts and
# pull every reachable peer's advert in the background, so the section can
# repaint without the request waiting on a sleeping machine.
# POST /manager/crew/advertise
sub action_10477 {
	my $c = shift;
	unless (($c->session('authentication') || '') eq 'approved') { $c->rendered(403); return; }
	my $abilities = &crew::tick();
	&subs::subprocessor(sub {
		eval { &crew::advert_sync(); };
	}, { name => 'crew advert (on demand)' });
	$c->render(json => {
		ok          => 1,
		signatorial => &subs::signatorial_designer(),
		hostname    => $abilities->{'hostname'},
		abilities   => $abilities,
		at          => &subs::rightNow(),
	});
}

# GET /manager/voice_release
sub action_10513 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm) { $c->rendered(403); return; }
	my $hostname = `hostname`; chomp $hostname;
	$c->render(json => { hostname => $hostname, signatorial => &subs::signatorial_designer(), voices => &voice_lister() });
}

# GET /manager/voice_download
sub action_10521 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm) { $c->rendered(403); return; }
	my $file = $c->param('file') || '';
	# a plain model filename inside voices/, never a path
	unless ($file =~ /^[A-Za-z0-9_.-]+\.onnx(\.json)?$/) { $c->rendered(404); return; }
	my $path = &subs::voices_dir() . '/' . $file;
	unless (-f $path) { $c->rendered(404); return; }
	$c->res->headers->content_type('application/octet-stream');
	$c->res->headers->content_disposition('attachment; filename="' . $file . '"');
	$c->res->content->asset(Mojo::Asset::File->new(path => $path));
	$c->rendered(200);
}

# v3 producer: one table's rows in a bounded, encrypted batch. Deliberately no
# temp SQLite: the caller's cursor is a rowid, and the response is Sereal+zstd
# sealed with the same shared security credential the snapshot container uses.
# The route peer_verifies the caller (or accepts an approved session), exactly
# like the rest of the sync rail.
# GET /manager/sync_rows
sub action_11014 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless (($c->session('authentication') || '') eq 'approved' || ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm))) {
		$c->rendered(403);
		return;
	}
	my $suds = &subs::session_suds($c) || &subs::suds_grabber();
	my $security = &subs::db_select('security', ['credential'], { level => 1 })->hash || {};
	my $secret = &subs::decrypter($suds, $security->{'credential'} || '');
	unless (defined $secret && length $secret) {
		$c->render(json => { ok => 0, error => 'no shared credential' });
		return;
	}
	my $table = $c->param('table') || '';
	my %allowed = map { $_ => 1 } @{ &subs::sync_table_list() };
	unless ($allowed{$table}) {
		$c->render(json => { ok => 0, error => 'unknown table' });
		return;
	}
	# A peer is reading rows from this machine: the scheduled wake must not let
	# the CPU go while the pull is in flight.
	&subs::sync_pull_touch();
	my $cut = $c->param('cut');
	$cut = 0 unless defined $cut && $cut =~ /^[0-9]+$/;
	my $limit = $c->param('limit');
	$limit = 500 unless defined $limit && $limit =~ /^\d+$/ && $limit > 0 && $limit <= 2000;
	my $after = $c->param('after');
	$after = '' unless defined $after && $after =~ /^\d+$/;
	# A band request names a half-open server_time range instead of a lower cut.
	# The bucket repair walks bands this way; `cut` stays for every other caller.
	my $from = $c->param('from');
	my $to = $c->param('to');
	my ($where, @args);
	if (defined $from && $from =~ /^-?\d+$/ && defined $to && $to =~ /^-?\d+$/ && $to > $from) {
		$where = ' where cast(server_time as integer) >= ? and cast(server_time as integer) < ?';
		@args = ($from + 0, $to + 0);
	}
	else {
		$where = ' where server_time >= ?';
		@args = ($cut);
	}
	my @after_args;
	if ($after ne '') {
		$where .= ' and rowid > ?';
		@after_args = ($after);
	}
	if ($table eq 'appointments') { $where .= " and (status is null or status != 'deleting')"; }
	elsif ($table eq 'settings') { $where .= " and (setting is null or setting not in ('open_tabs','scrollTop','jopen','dimensions'))"; }
	my $total = 0;
	if ($after eq '') {
		# A cut-free first batch is a whole-table read, the one expensive shape
		# this route serves. It used to leave no trace of its owner: a peer
		# walking 115k rows held a worker hot for minutes and the log named
		# nothing. One line per pull, carrying the peer and the table.
		$log->info('sync rows: ' . ($signatorial || '?') . ' reads ' . $table . ' whole (cut=0, no band)') if $log && !defined $from && $cut == 0;
		$total = &subs::db_query('select count(*) as c from ' . $table . $where, @args)->hashes->[0]->{'c'} || 0;
	}
	my $rows = &subs::db_query('select rowid as __sync_rowid, * from ' . $table . $where . ' order by rowid limit ?', @args, @after_args, $limit + 1)->hashes || [];
	my $more = scalar(@{$rows}) > $limit ? 1 : 0;
	splice @{$rows}, $limit if $more;
	my $next = '';
	$next = $rows->[-1]->{'__sync_rowid'} if $more && scalar @{$rows};
	my $plain = eval { encode_sereal({ ok => 1, table => $table, rows => $rows, total => $total, next => $next, done => ($more ? 0 : 1), server_time => &subs::rightNow() }, { compress => SRL_ZSTD, compress_level => 3 }) };
	unless (defined $plain) {
		$c->render(json => { ok => 0, error => 'could not encode the batch' });
		return;
	}
	my $sealed = eval { &subs::encrypter($secret, $plain) };
	unless (defined $sealed) {
		$c->render(json => { ok => 0, error => 'could not seal the batch' });
		return;
	}
	$c->res->headers->content_type('application/octet-stream');
	$c->render(data => $sealed);
}

# The durable deletion log, in one small plain reply. A machine that pulls rows
# but never reaches the donor's handshake (out of its hub's range, say) still
# learns what the donor deleted; the puller applies these after its merge and
# advances its confirmed cursor. Peer-gated exactly like `/manager/sync_rows`;
# the reply carries names and ids, never a record's contents.
# GET /manager/sync_tombstones
sub action_11091 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless (($c->session('authentication') || '') eq 'approved' || ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm))) {
		$c->rendered(403);
		return;
	}
	&subs::sync_pull_touch();
	my $cursor = $c->param('cursor');
	$cursor = 0 unless defined $cursor && $cursor =~ /^\d+$/;
	$c->render(json => {
		tombstones => &subs::tombstones_since($cursor),
		sync_cursor => &subs::tombstone_max(),
	});
}

# One table's band map: the handshake digest's count/sum/max, per server_time
# band. Asked for only when a whole-table digest has moved, so a repair can name
# the bands that differ instead of re-reading the table. Peer-gated and sealed
# exactly like `/manager/sync_rows`.
# GET /manager/sync_buckets
sub action_11111 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless (($c->session('authentication') || '') eq 'approved' || ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm))) {
		$c->rendered(403);
		return;
	}
	my $suds = &subs::session_suds($c) || &subs::suds_grabber();
	my $security = &subs::db_select('security', ['credential'], { level => 1 })->hash || {};
	my $secret = &subs::decrypter($suds, $security->{'credential'} || '');
	unless (defined $secret && length $secret) {
		$c->render(json => { ok => 0, error => 'no shared credential' });
		return;
	}
	my $table = $c->param('table') || '';
	my %allowed = map { $_ => 1 } (@{ &subs::sync_table_list() }, 'settings_durable');
	unless ($allowed{$table}) {
		$c->render(json => { ok => 0, error => 'unknown table' });
		return;
	}
	&subs::sync_pull_touch();
	my $band = $c->param('band');
	# Refuse a tiny band before the group-by runs: a per-millisecond band would
	# name a bucket per row and build a map the caller cannot use anyway. An
	# absent band means the default; anything else must be sane.
	if (defined $band && length $band && !($band =~ /^\d+$/ && $band >= 3600000)) {
		$c->render(json => { ok => 0, error => 'band too small' });
		return;
	}
	my $map = &subs::sync_table_buckets($table, $band);
	if (scalar(keys %{ $map->{'buckets'} }) > 20000) {
		$c->render(json => { ok => 0, error => 'too many buckets' });
		return;
	}
	my $plain = eval { encode_sereal({ ok => 1, table => $table, band => $map->{'band'}, buckets => $map->{'buckets'}, server_time => &subs::rightNow() }, { compress => SRL_ZSTD, compress_level => 3 }) };
	unless (defined $plain) {
		$c->render(json => { ok => 0, error => 'could not encode the buckets' });
		return;
	}
	my $sealed = eval { &subs::encrypter($secret, $plain) };
	unless (defined $sealed) {
		$c->render(json => { ok => 0, error => 'could not seal the buckets' });
		return;
	}
	$c->res->headers->content_type('application/octet-stream');
	$c->render(data => $sealed);
}

# POST /manager/backup/confirm
sub action_11638 {
	my $c = shift;
	# confirmed over the same gate-exempt signed rail: a session or a peer
	# signature (the caller names itself in `signatorial`).
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless (($c->session('authentication') || '') eq 'approved' || ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm))) {
		$c->rendered(403);
		return;
	}
	my $backup_confirm = eval { return decode_json $c->param('backup_confirm') };
	my $backup_data = $backup_confirm->{'backup_data'};
	my $returner = $backup_data;
	if ($backup_data->{'server_time'}) {
		# This is the *completed* snapshot. It was built with reason
		# `remote_update` (the in-flight name), and storing it under that name
		# meant backup_now's watermark query - which looks for `remote_upgraded`
		# - never found it. Every pull then looked like a cold peer and re-exported
		# the whole database, holding the single export lock while it did and
		# telling every other machine "already exporting". Store the confirmation
		# under the name the watermark actually reads.
		$backup_data->{'reason'} = 'remote_upgraded' if (!$c->param('gimme') && ($backup_data->{'reason'} || '') eq 'remote_update');
		my $signatorial = &subs::signatorial_designer();
		my $defunct_backups = &subs::db_query('select * from backups where recipient = ? and signatorial = ? and ost < ?', $backup_data->{'recipient'}, $signatorial, $backup_confirm->{'ld_server_time'})->hashes;
		foreach my $defb ( @{$defunct_backups} ) {
			if ($defb->{'enc_file'} && -e $defb->{'enc_file'}) {
				my $delb = $defb->{'enc_file'};
				`shred -u $delb`;
			}
			&deletion_registration({ table => 'backups', uuid => $defb->{'uuid'}, scope => 'single', server_time => $defb->{'server_time'} });
			&subs::db_delete('backups', { uuid => $defb->{'uuid'} });
		}
		my $last_updated = &subs::db_query('delete from backups where recipient = ? and signatorial = ? and ost <= ?', $backup_data->{'recipient'}, $signatorial, $backup_data->{'ld_server_time'});
		&subs::db_insert('backups', $backup_data);
	}
	if (-e $backup_data->{'enc_file'}) {
		my $f = $backup_data->{'enc_file'};
		`shred -u $f`;
	}
	# The puller's confirmation is what makes a migration done: mark the
	# snapshot row it was waiting on, so Dev's status follows the real finish
	# rather than the build's ready.
	&subs::db_update('sync_snapshots', { state => 'done', updated => &subs::rightNow() }, { archive_path => $backup_data->{'enc_file'} }) if $backup_data->{'enc_file'};
	$c->render(json => $returner);
}

# Resolve a peer's own Manager address for a window of its own. The window is
# top-level (the desktop app's), never a frame served from this house: its
# origin is the peer's, so localStorage and cookies stay that machine's own and
# do not mix with the local manager's. A manager URL is accepted only when it
# is one this house already knows from remote_machines.
# GET /manager/remote_manager
sub action_11740 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $manager = $c->param('manager') || '';
	my $rm;
	if ($uuid) {
		$rm = &subs::remote_machine_lister({ uuid => $uuid, self => 'no', limit => 1 });
	}
	if (!(ref $rm eq 'HASH' && $rm->{'manager'}) && $manager ne '') {
		my $want = $manager;
		$want =~ s{/manager/?$}{}i;
		$want =~ s{/+$}{};
		my ($want_host) = $want =~ m{^https?://([^/:]+)}i;
		foreach my $candidate ( @{ &subs::remote_machine_lister({ self => 'no' }) } ) {
			next unless $candidate->{'manager'};
			my $have = $candidate->{'manager'};
			$have =~ s{/manager/?$}{}i;
			$have =~ s{/+$}{};
			# A stored Go link can name an address the row has since moved off
			# (the LAN fallback, or a tunnel port): accept the row when the
			# host is still one of its own.
			my @hosts = grep {
				defined $_ && $_ ne ''
					&& $_ !~ /^(?:127\.0\.0\.1|localhost|\[?::1\]?)$/i
			} ($candidate->{'ip'}, $candidate->{'fqdn'}, $candidate->{'domain'}, $candidate->{'lan_ip'}, $candidate->{'vip'});
			if ($have eq $want || ($want_host && grep { $_ eq $want_host } @hosts)) { $rm = $candidate; last; }
		}
	}
	return $c->render(text => 'no such machine', status => 404) unless ref $rm eq 'HASH' && $rm->{'manager'};
	my $url = $rm->{'manager'};
	$url =~ s{/manager/?$}{}i;
	$url =~ s{/+$}{};
	return $c->render(text => 'no address for that machine', status => 404) unless $url =~ m{^https?://[^\s"'<>]+$}i;
	$url .= '/manager';
	my $name = $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'domain'} || $rm->{'ip'} || 'remote';
	# The window must sign the peer in with the device this session's app key
	# belongs to. The page's localStorage can hold an older (or a browser)
	# device id, so the server is the authority on it.
	# app_device is the row the app login just verified; device_uuid is the
	# paired session's own. Prefer the former when it exists.
	my $session_device_uuid = $c->session('app_device') || $c->session('device_uuid') || '';
	my $session_device = $session_device_uuid
		? &subs::db_select('paired_devices', [ 'uuid', 'app_pubkey' ], { uuid => $session_device_uuid, status => 'active' })->hash
		: undef;
	# The Go window is the peer's own manager, on the peer's own domain. The
	# Gate there asks for a second factor - approve from one of the person's
	# devices, or the laptop's fingerprint - and that confirmation is the point
	# for a browser: a ticket that redeemed itself would sign the browser in
	# behind the person's back. The installed apps are different: their session
	# already proved this device's app key, and pressing Go there is the person's
	# own deliberate step, so they may mint the ticket. If the house has a
	# reader or a paired phone/tablet, the mint waits for that fingerprint first.
	my $browse_host = $rm->{'fqdn'} || $rm->{'domain'} || '';
	# A mirror learned through a peer can carry that peer's loopback as its fqdn
	# (the app's own address). For a remote machine that names this house, not
	# the peer, so it must never become the Go window's host.
	$browse_host = '' if $browse_host =~ /^(?:127\.0\.0\.1|localhost|\[?::1\]?)$/i;
	my $browse_port = eval { Mojo::URL->new($url)->port } || $rm->{'port'} || 443;
	if ($browse_host) {
		$url = 'https://' . $browse_host . ':' . $browse_port . '/manager';
	}
	# A peer reached through a tunnel is often stored as 127.0.0.1:<tunnel port>
	# on the machine that owns the tunnel. The Go window opens on THIS machine,
	# where that loopback is not the peer, so use an address the peer advertises
	# (tailnet/LAN/ip) and its own manager port. A remote's window must never be
	# handed this house's loopback.
	my ($url_host) = $url =~ m{^https?://([^/:]+)}i;
	if (($url_host || '') =~ /^(?:127\.0\.0\.1|localhost|\[?::1\]?)$/i) {
		(my $alt = $rm->{'tailnet_ip'} || $rm->{'lan_ip'} || $rm->{'ip'} || '') =~ s/^\s+|\s+$//g;
		if ($alt ne '' && $alt !~ /^(?:127\.|localhost|\[?::1\]?)$/i) {
			$url = 'https://' . $alt . ':' . ($rm->{'port'} || $browse_port || 45545) . '/manager';
		}
		else {
			return $c->render(text => 'no address for that machine', status => 404);
		}
	}
	# app_device is set only by app_login, which is the installed app proving
	# its device key. A remote manager window opened by the app can instead be a
	# ticket session, but it still carries the app's own desktop/bridge flags;
	# a plain browser carries neither. Both are the app's deliberate Go.
	my $in_app = &subs::go_from_app({
		app_device => $c->session('app_device'),
		desktop => $c->param('desktop'),
		bridge => $c->param('bridge'),
	});
	my $ticket_url = '';
	my $need_approval = 0;
	my $request_id = '';
	my $fingerprint = 0;
	my $phone_fingerprint = 0;
	my $devices = [];
	if ($in_app) {
		# app_login already proved this install's key, and pressing Go in the
		# app is the person's own deliberate step. Mint the peer ticket now
		# instead of waiting on a second factor the person cannot see. A
		# browser never reaches this branch: it has no app_device, gets no
		# ticket, and is told to use the app.
		$ticket_url = eval { &remote_manager_ticket($c, $rm) } || '';
	}
	my $ticket_failed = ($in_app && !$ticket_url && !$need_approval) ? 1 : 0;
	$log->info('remote_manager: uuid=' . (defined $uuid ? $uuid : '-') . ' manager=' . ($manager || '-') . ' -> ' . $url . ' ticket=' . ($ticket_url ? 1 : 0) . ' approval=' . $need_approval . ' desktop=' . ($c->param('desktop') || '?') . ' bridge=' . ($c->param('bridge') || '?') . ' ticket_failed=' . $ticket_failed . ' in_app=' . $in_app . ' app_until=' . ($c->session('app_until') || 0) . ' app_device=' . (($c->session('app_device') || '') ne '' ? 1 : 0) . ' auth=' . ($c->session('authentication') || '-') . ' host=' . ($c->req->url->host || '-'));
	$c->render(json => {
		manager => $url,
		ticket_url => $ticket_url,
		ticket_failed => $ticket_failed,
		need_approval => $need_approval,
		request_id => $request_id,
		fingerprint => $fingerprint,
		phone_fingerprint => $phone_fingerprint,
		devices => $devices,
		uuid => $rm->{'uuid'} || '',
		name => $name,
		device_uuid => $session_device_uuid,
		app_key => ($session_device && $session_device->{'app_pubkey'}) ? 1 : 0
	});
}

1;
