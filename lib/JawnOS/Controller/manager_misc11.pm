package Manager;

# manager_misc11: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/remote_input
sub action_35907 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	# Input is the most intimate thing a peer can ask for, so it sits on the
	# Trusted rung rather than with the ordinary house actions.
	unless (&subs::peer_allows($c, $rm, 'remote_control')) {
		$c->render(json => { ok => 0, error => 'this machine needs Trusted access for remote input' });
		return;
	}
	my $raw = $c->param('events') || '[]';
	my $events = length($raw) <= 65536 ? eval { decode_json $raw } : undef;
	unless (ref $events eq 'ARRAY') {
		$c->render(json => { ok => 0, error => 'no events' });
		return;
	}
	# Every event is a process for the backend, so one batch cannot be made to
	# hold the worker for an unbounded time.
	$#$events = 119 if @{$events} > 120;
	my $backend = &remote_input::backend();
	my $geometry = &remote_input_geometry();
	my $applied = &remote_input_apply($events);
	$c->render(json => {
		ok => 1,
		applied => $applied,
		backend => $backend,
		screen => ($geometry ? [ $geometry->[0], $geometry->[1] ] : undef),
		clipboard => $remote_input_clipboard
	});
}

# The same input over one persistent socket. The HTTP route above signs and
# verifies every batch with an openssl process at each end; a live keyboard
# cannot pay that on every character. The socket is opened once, signed at the
# handshake, and frames after that are just bytes in order.
# WEBSOCKET /manager/remote_input/ws
sub action_35942 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	unless (&subs::peer_allows($c, $rm, 'remote_control')) { $c->rendered(403); return; }
	my $geometry = &remote_input_geometry();
	$c->send(&remote_input_frame({
		t => 'hello',
		backend => &remote_input::backend(),
		screen => ($geometry ? [ $geometry->[0], $geometry->[1] ] : undef),
	}));
	$c->on(message => sub($ws, $msg) {
		my $m = eval { decode_json $msg } || {};
		my $events = $m->{'events'};
		$events = eval { decode_json $events } unless ref $events eq 'ARRAY';
		return unless ref $events eq 'ARRAY';
		$#$events = 119 if @{$events} > 120;
		my $want_clipboard = grep { ref $_ eq 'HASH' && (($_->{'t'} || '') eq 'clipboard_get') } @{$events};
		&remote_input_apply($events);
		$ws->send(&remote_input_frame({ t => 'clipboard', text => ($remote_input_clipboard // '') })) if $want_clipboard;
		# A release ends the session; the target closes the control socket so an
		# idle authenticated channel does not outlive the hold.
		if (grep { ref $_ eq 'HASH' && (($_->{'t'} || '') eq 'release') } @{$events}) {
			$ws->finish;
		}
	});
}

# POST /manager/remote_input/send
sub action_36160 {
	my $c = shift;
	my $uuid = $c->param('remote_uuid');
	unless ($uuid) { $c->render(json => { ok => 0, error => 'no machine selected' }); return; }
	my $events = $c->param('events') || '[]';
	# The browser bounds its own queue; this is the server's backstop against a
	# caller that ignores the rules.
	if (length($events) > 65536) { $c->render(json => { ok => 0, error => 'too many events at once' }); return; }
	$c->render(json => remote_input_send({
		uuid => $uuid, events => $events, browser_tab_id => $c->param('browser_tab_id')
	}));
}

# The remote_control panel's VPN button. The exit node is a property of this
# machine's own tailnet client, so the route changes it here: Linux peers run
# tailscale set, and the Android WebView uses its JawnVPN bridge instead.
# GET /manager/tailnet/status
sub action_36175 {
	my $c = shift;
	$c->render(json => &subs::tailnet_status());
}

# POST /manager/tailnet/exit
sub action_36179 {
	my $c = shift;
	$c->render(json => &subs::tailnet_set_exit($c->param('ip')));
}

# GET /manager/public_ip
sub action_36190 {
	my $c = shift;
	my $choice = &subs::public_ip_check_choice();
	if ($choice eq 'none') {
		$c->render(json => { ok => 0, ip => '', disabled => 1 });
		return;
	}
	my $now = &subs::rightNow();
	if (!$c->param('refresh') && $public_ip_memo && ($public_ip_memo->{'at'} || 0) > $now - 30000) {
		$c->render(json => { ok => ($public_ip_memo->{'ip'} ? 1 : 0), ip => $public_ip_memo->{'ip'} || '', cached => 1 });
		return;
	}
	my @urls = &subs::public_ip_check_urls();
	my $ua = Mojo::UserAgent->new(connect_timeout => 3, inactivity_timeout => 4, request_timeout => 5);
	my $try;
	$try = sub {
		my $url = shift @urls;
		unless ($url) {
			$public_ip_memo = { ip => '', at => &subs::rightNow() };
			$c->render(json => { ok => 0, ip => '' });
			return;
		}
		$ua->get_p($url)->then(sub {
			my $tx = shift;
			my $ip = '';
			if ($tx->res->is_success) {
				my $text = $tx->res->text || '';
				my ($marked) = $text =~ /^ip=(.+)$/m;
				$ip = defined $marked ? $marked : $text;
				$ip =~ s/^\s+|\s+$//g;
			}
			$ip = &subs::public_ip_only($ip);
			if ($ip) {
				$public_ip_memo = { ip => $ip, at => &subs::rightNow() };
				$c->render(json => { ok => 1, ip => $ip });
				return;
			}
			$try->();
		})->catch(sub { $try->(); });
	};
	$try->();
}

# The agents list: newest first. A row that is not open is history - the
# client keeps the open ones, and pressing a history row re-opens it.
# Work claims: who is sorting out what, so two agents - or two machines - do not
# take the same job. Stored on the 'claims' app (not one of @gb::protected), so the
# mesh merge carries them to every machine, the same way appointments stay in step.
# GET /manager/work_claims
sub action_37173 {
	my $c = shift;
	$c->render(json => { claims => &subs::work_claims() });
}

# POST /manager/work_claim
sub action_37177 {
	my $c = shift;
	my $task = $c->param('task') // '';
	$task =~ s/[^A-Za-z0-9_-]//g;
	unless (length $task) { $c->render(json => { error => 'need a task' }); return; }
	my $claim = &subs::claim_work($task, $c->param('note'));
	$c->render(json => { ok => 1, task => $task, claim => $claim });
}

# POST /manager/work_claim/release
sub action_37185 {
	my $c = shift;
	my $task = $c->param('task') // '';
	$task =~ s/[^A-Za-z0-9_-]//g;
	unless (length $task) { $c->render(json => { error => 'need a task' }); return; }
	&subs::release_work($task);
	$c->render(json => { ok => 1, task => $task });
}

# GET /manager/agents/list
sub action_37193 {
	my $c = shift;
	&agent_registry_adopt();
	my @out;
	foreach my $r ( @{ &agent_registry() } ) {
		push @out, {
			kind => (($r->{'kind'} || '') eq 'coding' ? 'coding' : 'guide'),
			name => ($r->{'name'} || ''),
			title => ($r->{'title'} || $r->{'name'} || ''),
			turns => ($r->{'turns'} || 0) + 0,
			preview => ($r->{'preview'} || ''),
			updated => ($r->{'updated'} || $r->{'created'} || 0),
		};
	}
	@out = sort { ($b->{'updated'} || 0) <=> ($a->{'updated'} || 0) } @out;
	$c->render(json => { agents => \@out });
}

# One thread's remembered turns (what a re-opened chat shows) and its title.
# GET /manager/agents/thread
sub action_37211 {
	my $c = shift;
	my $kind = ($c->param('kind') // '') eq 'coding' ? 'coding' : 'guide';
	my $name = $c->param('name') // '';
	$name =~ s/[^A-Za-z0-9_-]//g;
	my $turns = $kind eq 'coding' ? coding_conversation_load($name) : guide_conversation_load($name);
	my ($row) = grep { ($_->{'kind'} || '') eq $kind && ($_->{'name'} || '') eq $name } @{ &agent_registry() };
	$c->render(json => { kind => $kind, name => $name, title => ($row ? ($row->{'title'} || '') : ''), transcript => $turns });
}

# A guide associate's turns, saved as it goes so the history list knows where
# the thread stood. (The Coding agent's own route saves its side; this is the
# Guide half of the same registry.)
# POST /manager/agents/save
sub action_37223 {
	my $c = shift;
	my $kind = ($c->param('kind') // '') eq 'coding' ? 'coding' : 'guide';
	my $name = $c->param('name') // '';
	$name =~ s/[^A-Za-z0-9_-]//g;
	$name = 'assistant' unless length $name;
	# decode from bytes: Mojo hands params back as character strings, and a single
	# non-ASCII character (an em dash in the guide's own wording) would make
	# decode_json fail - which is how a good thread came back as an empty one.
	my $transcript_json = $c->param('transcript') // '';
	utf8::encode($transcript_json) if utf8::is_utf8($transcript_json);
	my $transcript = eval { decode_json $transcript_json } || [];
	$transcript = [] unless ref $transcript eq 'ARRAY';
	# An empty save must not wipe a thread that has something in it: a client-side
	# debounce that outlived its thread, or a decode that met a character, would
	# otherwise blank the turns the list counts. Nothing clears a conversation
	# through a save - deleting is its own route.
	unless (scalar @{$transcript}) {
		my $standing = $kind eq 'coding' ? coding_conversation_load($name) : guide_conversation_load($name);
		if (scalar @{$standing}) {
			return $c->render(json => { ok => 1, skipped => 'empty', name => $name, kind => $kind });
		}
	}
	if ($kind eq 'coding') { coding_conversation_save($name, $transcript); }
	else {
		my $warranty = &guide_message_warranty($name);
		foreach my $m ( @{$transcript} ) { $m->{'warranty'} = $warranty; }
		guide_conversation_save($name, $transcript);
	}
	my $row = &agent_registry_note($kind, $name, $transcript);
	$c->render(json => { ok => 1, title => ($row->{'title'} || ''), name => $name, kind => $kind });
}

# Throw an archived conversation away: its turns and its row in the registry.
# POST /manager/agents/delete
sub action_37256 {
	my $c = shift;
	my $kind = ($c->param('kind') // '') eq 'coding' ? 'coding' : 'guide';
	my $name = $c->param('name') // '';
	$name =~ s/[^A-Za-z0-9_-]//g;
	return $c->render(json => { error => 'no such conversation' }) unless length $name;
	&subs::setting_setter({ app => '__president', setting => ($kind eq 'coding' ? 'coding_conversation_' : 'guide_conversation_') . $name, value => encode_json([]) });
	&agent_registry_forget($kind, $name);
	$c->render(json => { ok => 1, kind => $kind, name => $name });
}

# The associate's replies, spoken: the same house voice the watch's answers use
# (Piper first - see say_it), on the machine the person is at. The ask is the
# associate's own setting, ticked in its config menu; the route re-checks it, so
# a stale page cannot speak after the tick is off.
# POST /manager/assistant/say
sub action_37270 {
	my $c = shift;
	my $text = $c->param('text') // '';
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return $c->render(json => { ok => 0 }) unless length $text;
	if ((&subs::setting_grabber({ app => '__president', setting => 'assistant_speech', device => 'all' }) // '') ne 'on') {
		return $c->render(json => { ok => 0, note => 'speech is off' });
	}
	my $spoken = substr($text, 0, 800);
	&subs::say_it($spoken);
	# the voice runs in a fork of its own, so the caller cannot hear it finish:
	# hand an estimate along (Piper paces about 2.5 words a second) so a spoken
	# conversation can hold its mic until the voice has had its say
	my $words = scalar( split /\s+/, $spoken );
	my $seconds = $words ? (0.8 + $words / 2.5) : 0;
	$c->render(json => { ok => 1, seconds => sprintf('%.1f', $seconds) });
}

# One run of the Coding agent, queued. The work happens in perl/Coding.pl, a
# process the master keeps across a tree restart (lib/JawnOS/Domain/Coding.pm),
# so a reload or a restart no longer costs the answer. The panel polls
# /manager/coding/run for the steps as they are written.
# POST /manager/coding/heal
sub action_37291 {
	my $c = shift;
	my $task = $c->param('task') // '';
	$task =~ s/^\s+|\s+$//g;
	unless (length $task) { $c->render(json => { error => 'Tell me what to change.' }); return; }
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	unless ($model) { $c->render(json => { error => "No Coding model is set (Configure \x{2192} Platform)." }); return; }
	my $conversation = $c->param('conversation') || 'coding';
	$conversation =~ s/[^A-Za-z0-9_-]//g;
	$conversation = 'coding' unless length $conversation;
	my $run = eval { &subs::coding_run_enqueue($task, $conversation) };
	unless ($run) {
		my $why = $@ || 'the coding queue could not be written';
		$why =~ s/\s+/ /g;
		$c->render(json => { error => 'Could not queue the run: ' . $why });
		return;
	}
	$c->render(json => { ok => 1, run => $run, conversation => $conversation, queued => 1 });
}

# The state of one run, or of the newest run for a conversation. This is what
# the panel polls: steps are appended by the worker between model turns, and
# the final answer lands in the same record.
# GET /manager/coding/run
sub action_37569 {
	my $c = shift;
	my $id = $c->param('id') // '';
	if ($id =~ /^[0-9]+$/) {
		$c->render(json => &subs::coding_run_view($id));
		return;
	}
	my $conversation = $c->param('conversation') || 'coding';
	$c->render(json => &subs::coding_run_current($conversation));
}

# Stop a run after the step it is on. The worker checks the flag between model
# turns; nothing already written to the repo is rolled back.
# POST /manager/coding/cancel
sub action_37570 {
	my $c = shift;
	my $id = $c->param('id') // '';
	unless ($id =~ /^[0-9]+$/) {
		my $conversation = $c->param('conversation') || 'coding';
		my $current = &subs::coding_run_current($conversation);
		$id = $current->{'run'} // '';
	}
	unless ($id =~ /^[0-9]+$/ && &subs::coding_run_cancel($id)) {
		$c->render(json => { ok => 0, error => 'no such run' });
		return;
	}
	$c->render(json => { ok => 1, run => $id + 0 });
}

# Approve or reject the commit a paused run is waiting on. The worker is asleep
# between two polls; it takes the answer off its own setting and either runs the
# commit it already showed or stops without one. The verdict is not written into
# the run snapshot: the worker owns that, and two writers of one blob lose one.
# POST /manager/coding/approve
sub action_37571 {
	my $c = shift;
	my $id = $c->param('id') // '';
	unless ($id =~ /^[0-9]+$/) {
		my $conversation = $c->param('conversation') || 'coding';
		my $current = &subs::coding_run_current($conversation);
		$id = $current->{'run'} // '';
	}
	my $state = $id =~ /^[0-9]+$/ ? &subs::coding_run_state_load($id) : {};
	unless (ref $state eq 'HASH' && ($state->{'state'} // '') eq 'awaiting_approval') {
		$c->render(json => { error => 'no run awaiting approval' });
		return;
	}
	# A paused review is only answered by the worker that opened it.
	unless (&subs::coding_worker_alive()) {
		$c->render(json => { error => 'the background coding process is not running, so nothing would take the answer' });
		return;
	}
	&subs::coding_verdict_set($id, 'approve');
	$c->render(json => { ok => 1 });
}

# POST /manager/coding/reject
sub action_37572 {
	my $c = shift;
	my $id = $c->param('id') // '';
	unless ($id =~ /^[0-9]+$/) {
		my $conversation = $c->param('conversation') || 'coding';
		my $current = &subs::coding_run_current($conversation);
		$id = $current->{'run'} // '';
	}
	my $state = $id =~ /^[0-9]+$/ ? &subs::coding_run_state_load($id) : {};
	unless (ref $state eq 'HASH' && ($state->{'state'} // '') eq 'awaiting_approval') {
		$c->render(json => { error => 'no run awaiting approval' });
		return;
	}
	unless (&subs::coding_worker_alive()) {
		$c->render(json => { error => 'the background coding process is not running, so nothing would take the answer' });
		return;
	}
	&subs::coding_verdict_set($id, 'reject');
	$c->render(json => { ok => 1 });
}

# Start a fresh conversation: forget the stored thread so the next run begins clean.
# POST /manager/coding/forget
sub action_37338 {
	my $c = shift;
	my $conversation = $c->param('conversation') || 'coding';
	$conversation =~ s/[^A-Za-z0-9_-]//g;
	$conversation = 'coding' unless length $conversation;
	coding_conversation_save($conversation, []);
	&agent_registry_note('coding', $conversation, []);
	$c->render(json => { ok => 1, conversation => $conversation });
}

# ---- the records watch (the database's self-heal) --------------------------
# The fixed audit of the appointments table for the fault classes that corrupt
# the person's numbers. This route is the dry run: it returns the findings and
# the prompt the Coding agent would be given, and writes nothing. Staging,
# approval and Apply follow the error watch's shape (staged_records).
# GET /manager/records/audit
sub action_37352 {
	my $c = shift;
	my $h = $c->param('hours');
	# hours=0 is all time
	my $hours = (defined $h && $h =~ /^[0-9]+$/) ? $h : 48;
	my $report = &subs::records_audit($hours * 3600000);
	$c->render(json => { report => $report, prompt => &subs::records_audit_prompt() });
}

# A peer that holds a session's real end (the phone's accurate copy) closes it
# here over the signed rail: no browser session, no view to fan out, and only a
# row this machine already has. This is the quiet repair the records watch
# applies locally, which is what a peer needs when its own open row has a newer
# server_time than the stopped copy and the merge skips it.
# POST /manager/records/repair
sub action_37365 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	# A peer that holds the accurate copy asks this machine to clear the records a
	# bridge bug mangled (a millisecond date read as a span of minutes). This runs
	# only the unmistakable bad-date pass, is idempotent, and writes through the
	# same tombstones the mesh already uses; the caller is a pinned, signed peer.
	if (($c->param('mode') || '') eq 'bad_dates') {
		my $res = &subs::records_repair_bad_dates();
		$c->render(json => { ok => 1, mode => 'bad_dates', %{$res} });
		return;
	}
	my $app = &subs::unformat_name($c->param('app'));
	my $uuid = $c->param('uuid');
	my $action = $c->param('action') || 'repair';
	my $stop = $c->param('stop_timestamp');
	my $start = $c->param('timestamp');
	unless ($app && $uuid) {
		$c->render(json => { ok => 0, error => 'app and uuid are required' });
		return;
	}
	my $row = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hash;
	unless ($row) { $c->render(json => { ok => 0, error => 'no such session' }); return; }
	# An orphan the accurate copy does not hold at all is removed, not closed:
	# the tombstone is what stops a peer re-adding it on the next merge.
	if ($action eq 'delete') {
		&subs::records_tombstone($app, $uuid);
		$c->render(json => { ok => 1, deleted => $uuid, app => $app });
		return;
	}
	unless (defined $stop && $stop =~ /^\d+$/) {
		$c->render(json => { ok => 0, error => 'stop_timestamp is required to repair' });
		return;
	}
	$start = $row->{'timestamp'} unless (defined $start && $start =~ /^\d+$/);
	unless (defined $start && $start =~ /^\d+$/ && $stop >= $start) {
		$c->render(json => { ok => 0, error => 'stop_timestamp must not precede the start' });
		return;
	}
	my $dur = &subs::records_repair($app, $uuid, $start, $stop);
	$c->render(json => { ok => 1, app => $app, uuid => $uuid, timestamp => $start, stop_timestamp => $stop, duration => $dur });
}

# The records watch's staging area: the findings the audit staged, each with the
# actions it proposes. Review, apply, discard - the same shape as the error
# watch's fixes, and the same rule: nothing is written until Apply.
# POST /manager/records/scan
sub action_37412 {
	my $c = shift;
	my $hours = $c->param('hours');
	my $window = (defined $hours && $hours =~ /^[0-9]+$/) ? $hours * 3600000 : 172800000;
	$c->render(json => &subs::records_stage_scan($window));
}

# GET /manager/records/fixes
sub action_37418 {
	my $c = shift;
	my $rows = eval { &subs::db_query('select * from staged_records where status in (?, ?, ?) order by ost desc limit 100', 'new', 'proposed', 'failed')->hashes } || [];
	my @out;
	foreach my $r ( @{$rows} ) {
		push @out, {
			uuid => $r->{'uuid'}, kind => $r->{'kind'}, app => $r->{'app'},
			signature => $r->{'signature'}, sample => $r->{'sample'},
			proposed => (eval { decode_json $r->{'proposed'} } || {}),
			status => $r->{'status'}, note => $r->{'note'}, last_seen => $r->{'last_seen'},
		};
	}
	$c->render(json => { findings => \@out });
}

# GET /manager/records/fixes_fixed
sub action_37432 {
	my $c = shift;
	my $rows = eval { &subs::db_query('select * from staged_records where status = ? order by ost desc limit 200', 'applied')->hashes } || [];
	$c->render(json => { fixed => [ map { { uuid => $_->{'uuid'}, kind => $_->{'kind'}, app => $_->{'app'}, sample => $_->{'sample'}, note => $_->{'note'}, last_seen => $_->{'last_seen'} } } @{$rows} ] });
}

# POST /manager/records/fixes_apply
sub action_37437 {
	my $c = shift;
	$c->render(json => &subs::records_fix_apply($c->param('uuid')));
}

# POST /manager/records/fixes_discard
sub action_37441 {
	my $c = shift;
	&subs::db_update('staged_records', { status => 'discarded' }, { uuid => $c->param('uuid') });
	$c->render(json => { discarded => $c->param('uuid') });
}

# POST /manager/records/fixes_retry
sub action_37446 {
	my $c = shift;
	&subs::db_update('staged_records', { status => 'proposed', note => '' }, { uuid => $c->param('uuid') });
	$c->render(json => { retried => $c->param('uuid') });
}

# Talk a finding through with the Coding agent before applying it: a real
# appointment can be surprisingly long, so the audit finds and the agent reads.
# POST /manager/records/fixes_ask
sub action_37453 {
	my $c = shift;
	my $answer = &subs::records_ask($c->param('uuid'), $c->param('question'), $c->param('history'));
	$c->render(json => { answer => $answer });
}

# "Leave this app alone": a class of appointment the person knows is real (a home
# stay, a long ailment). The audit never reports that app again until the setting
# is cleared by hand.
# POST /manager/records/fixes_exempt
sub action_37461 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $row = eval { &subs::db_select('staged_records', undef, { uuid => $uuid })->hash };
	my $app = $c->param('app') || ($row && $row->{'app'});
	&subs::records_exempt_add($app) if $app;
	&subs::db_update('staged_records', { status => 'discarded', note => 'left alone by the person' }, { uuid => $uuid }) if $uuid;
	$c->render(json => { exempt => $app });
}

# POST /manager/records/fixes_clear
sub action_37470 {
	my $c = shift;
	&subs::db_query('delete from staged_records');
	$c->render(json => { ok => 1 });
}

# ---- the error watch's staging area ---------------------------------------
# The watcher (President) records every new error in staged_fixes; with a Coding
# model set, the agent stages a proposed fix on the row. These routes list what
# is waiting, throw a row away, and apply one - writing its files, checking
# they compile, then the finishing routine (bump, commit, push). Restarting so
# an applied fix goes live is the person's own word, from the panel's button.
# GET /manager/coding/fixes
sub action_37481 {
	my $c = shift;
	my $rows = eval { &subs::db_query('select * from staged_fixes where status in (?, ?, ?) order by ost desc limit 50', 'new', 'proposed', 'failed')->hashes } || [];
	my @out;
	foreach my $r ( @{$rows} ) {
		my $files = eval { decode_json $r->{'files'} } || {};
		push @out, {
			uuid => $r->{'uuid'},
			source => $r->{'source'},
			signature => $r->{'signature'},
			sample => $r->{'sample'},
			tally => ($r->{'tally'} || 0) + 0,
			status => $r->{'status'},
			model => $r->{'model'},
			summary => $r->{'summary'},
			note => $r->{'note'},
			created => $r->{'ost'},
			last_seen => $r->{'last_seen'},
			files => [ map { { path => $_, bytes => length($files->{$_}) } } sort keys %{$files} ],
		};
	}
	$c->render(json => {
		fixes => \@out,
		watching => ((&subs::setting_grabber({ app => 'mail', setting => 'error_watch' }) // '') eq 'on' ? 1 : 0),
	});
}

# The fixed list: every error the watch caught and the Coding agent fixed - a
# row turns 'applied' only once the finishing routine (bump, commit, push) has
# run, and its note carries when it shipped and the version it shipped as. Read
# from Configure -> Plat's Self-healing card, under the auto-heal tick.
# GET /manager/coding/fixes_fixed
sub action_37511 {
	my $c = shift;
	my $rows = eval { &subs::db_query('select * from staged_fixes where status = ? order by ost desc limit 100', 'applied')->hashes } || [];
	my @out;
	foreach my $r ( @{$rows} ) {
		my $files = eval { decode_json $r->{'files'} } || {};
		my ($applied, $version) = (($r->{'note'} || '') =~ /^applied\s+(\d+)(?:\s+as\s+v(\S+))?/) ? ($1, $2) : (undef, undef);
		push @out, {
			uuid => $r->{'uuid'},
			source => $r->{'source'},
			signature => $r->{'signature'},
			sample => $r->{'sample'},
			summary => $r->{'summary'},
			model => $r->{'model'},
			seen => ($r->{'tally'} || 0) + 0,
			created => $r->{'ost'},
			applied => $applied,
			version => $version,
			files => [ sort keys %{$files} ],
		};
	}
	$c->render(json => { fixed => \@out });
}

# POST /manager/coding/fixes_discard
sub action_37534 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $row = &subs::db_select('staged_fixes', undef, { uuid => $uuid })->hash;
	unless ($row) { $c->render(json => { error => 'no such caught error' }); return; }
	&subs::db_update('staged_fixes', { status => 'discarded' }, { uuid => $uuid });
	$c->render(json => { discarded => $uuid });
}

# POST /manager/coding/fixes_retry
sub action_37542 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $row = &subs::db_select('staged_fixes', undef, { uuid => $uuid })->hash;
	unless ($row) { $c->render(json => { error => 'no such caught error' }); return; }
	# back to the queue: the watcher proposes it again on a later pass (for a row
	# whose proposal failed - an unreachable model, a bad key - or one that sat
	# waiting for a model that has since been set)
	&subs::db_update('staged_fixes', { status => 'new', summary => '', note => '', files => '', steps => '' }, { uuid => $uuid });
	$c->render(json => { retried => $uuid });
}

# POST /manager/coding/fixes_clear
sub action_37553 {
	my $c = shift;
	# empty the list - the queue and its history: a caught error that comes back
	# is caught again from scratch, and an applied fix lives in git, not here
	&subs::db_query('delete from staged_fixes');
	$c->render(json => { ok => 1 });
}

# POST /manager/coding/fixes_apply
sub action_37560 {
	my $c = shift;
	# the engine lives in subroutines so the watch's auto-approve reaches the same
	# code: write the files, check the Perl, bump, commit what was written, push
	my $out = eval { &subs::staged_fix_apply($c->param('uuid')) };
	$out = { error => 'the apply failed: ' . ($@ || 'no result') } unless ref $out eq 'HASH';
	$c->render(json => $out);
}

# POST /manager/coding/restart
sub action_37568 {
	my $c = shift;
	&subs::restart_request('the coding panel asked for a restart');
	$c->render(json => { ok => 1 });
}

# ---- fatal browser JavaScript, reported by public/js/universal.js -----------
# The watch's third ear: an uncaught exception, an unhandled promise rejection,
# or a script/stylesheet that would not load, straight from whichever page hit
# it. Recorded the way the log watch records one (signature first, so a page
# throwing every frame is one row with a tally), and only while the watch is on.
# POST /manager/js_error
sub action_37578 {
	my $c = shift;
	return $c->render(json => { ok => 0 }) unless (&subs::setting_grabber({ app => 'mail', setting => 'error_watch' }) // '') eq 'on';
	my $body = eval { decode_json($c->req->body // '') } || {};
	my $message = $body->{'message'} // $c->param('message') // '';
	my $source = $body->{'source'} // $c->param('source') // '';
	my $line = (($body->{'line'} // $c->param('line') // 0) + 0);
	my $stack = $body->{'stack'} // '';
	my $page = $body->{'page'} // '';
	my $tally = ((($body->{'count'} // 1) + 0) || 1);
	$message =~ s/\s+/ /g;
	$message =~ s/^\s+|\s+$//g;
	return $c->render(json => { ok => 0 }) unless length $message || length $source;
	# a floor under a runaway page: the rows are cheap, but a thousand of them is
	# not a queue anyone wants to read
	my $staged = &subs::db_query("select count(*) as n from staged_fixes where source = 'js'")->hashes->[0];
	return $c->render(json => { ok => 0, note => 'enough browser errors staged for now' }) if $staged && ($staged->{'n'} || 0) >= 200;
	my $sample = 'JavaScript error on page ' . ($page || '?') . ': ' . $message
		. ($source ? ' (' . $source . ($line ? ':' . $line : '') . ')' : '')
		. (length $stack ? "\n" . substr($stack, 0, 1200) : '');
	my $row = &subs::staged_fix_note({
		source => 'js',
		sample => $sample,
		signature_text => $message . ' (' . $source . ':' . $line . ')',
		tally => $tally,
	});
	$c->render(json => { ok => 1, signature => ($row->{'signature'} || '') });
}

# POST /manager/handbook/settings
sub action_37667 {
	my $c = shift;
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $app = $c->param('app');
	my $handbook_settings = eval { return decode_json &subs::setting_grabber({ app => 'handbook', setting => $setting }) } || {};

	if ($handbook_settings->{$app} eq 'enabled') {
		undef $handbook_settings->{$app};
	}
	elsif ($setting eq 'favourites') {
		$handbook_settings->{$app} = 'enabled';
	}

	my $jsetting = encode_json $handbook_settings;
	&subs::setting_setter({ app => 'handbook', setting => $setting, value => $jsetting });

	$c->render(json => $handbook_settings);


}

# GET /manager/telephony
sub action_40591 {
	my $c = shift;
	$c->render(json => { ok => 1, %{ &telephony_status() } });
}

# The page's road when it is not inside the app's WebView (no window.JawnSms):
# the tree asks the device bridge itself. This was the app-that-has-not-landed
# fallback, termux-sms-send; the bridge is the only sender now.
# POST /manager/sms/device
sub action_40666 {
	my $c = shift;
	my $digits = $c->param('digits') || '';
	my $message = $c->param('message') || '';
	$digits =~ s/\S\d(?=\d{10})//;
	my $native = $digits ? &subs::device_call('sms.send', { number => $digits, message => $message }) : undef;
	$c->render(json => { ok => $native ? 1 : 0, via => $native ? 'bridge' : 'none' });
}

# The bridge's answer (window.__jawnSmsResult posts here): the send is logged,
# so a message that failed is visible in the log even when the UI is not. A
# saved MMS row also leaves its id for the mms route's short wait, and updates
# the house row if this machine already holds it (same uuid, now linked).
# POST /manager/sms/result
sub action_40678 {
	my $c = shift;
	my $ok = $c->param('ok');
	my $error = $c->param('error') || '';
	my $via = $c->param('via') || 'sms';
	my $id = $c->param('id') || '';
	my $mms_id = $c->param('mms_id') || 0;
	my $mms_date = $c->param('mms_date') || 0;
	my $mms_thread = $c->param('mms_thread') || 0;
	my $jawn_uuid = $c->param('jawn_uuid') || '';
	$log->info('sms bridge result: ok=' . ($ok || '?') . ' via=' . $via . ' id=' . $id . ' mms_id=' . $mms_id . ' mms_date=' . $mms_date . ' error=' . $error);
	# Only the mms bridge's own answer is the mms outcome. The page also reports
	# the hand-over itself ('mms_command', an immediate ok) and the plain text's
	# own send ('sms'); either would overwrite the real answer before the mms
	# route reads it, leaving the house row unlinked while the picture sits in
	# the system thread with no house row pointing at it.
	if ($jawn_uuid && $via ne 'mms_command' && $via ne 'sms') {
		my $result_file = &subs::home('~/.shots/sms_mms_result_' . $jawn_uuid . '.json');
		&write_file($result_file, encode_json({ ok => $ok, via => $via, mms_id => $mms_id, mms_date => $mms_date, mms_thread => $mms_thread, error => $error, server_time => &subs::rightNow() }));
		my $row = &subs::db_select('mailbox', undef, { uuid => $jawn_uuid })->hashes->[0];
		if ($row && $mms_id) {
			&subs::db_update('mailbox', &sms_mms_row_link($mms_id, $mms_date), { uuid => $jawn_uuid });
		}
	}
	$c->render(json => { received => 1 });
}

# A message with attachments on the sms road rides an MMS. The parts arrive as
# base64 (the sending machine may be any device in the house); they are written
# where the app can read them (the house's own termux home, same UID) and the
# page is handed the paths - window.JawnSms.mms sends them, or share() hands the
# OS messaging app the first when JawnOS is not the default sms app.
# POST /manager/sms/mms
sub action_40709 {
	my $c = shift;
	my $jawn_uuid = $c->param('jawn_uuid') || '';
	my $digits = $c->param('digits') || '';
	my $subject = $c->param('subject') || '';
	my $parts = eval { return decode_json $c->param('parts') } || [];
	# a wifi-only tablet is a 'mobile' device in the house, but it has no radio to
	# carry an MMS; answer so a relay can fall through to the phone
	if (&subs::device_setter() eq 'mobile' && !&telephony_status()->{'telephony'}) {
		$c->render(json => { ok => 0, error => 'no telephony on this device', parts => 0 });
		return;
	}
	$digits =~ s/\D+//g;
	$digits =~ s/^1//;
	my @local;
	foreach my $p ( @{$parts} ) {
		my $data = $p->{'data'} || '';
		next unless $data;
		my $name = $p->{'name'} || 'part';
		$name =~ s{[^A-Za-z0-9._-]}{_}g;
		my $mime = $p->{'mime'} || 'image/jpeg';
		my $dir = &subs::home('~/.shots/sms_parts');
		`mkdir -p $dir` unless -e $dir;
		my $file = $dir . '/' . &subs::random_string_creator(8) . '-' . $name;
		my $bytes = decode_base64($data);
		&write_file($file, $bytes);
		push @local, { path => &bridge_path($file), mime => $mime };
	}
	my $tabs = &subs::db_query("select browser_tab_id from websockets where app = ?", 'tab')->hashes;
	if (scalar @local == 0) {
		$c->render(json => { ok => 0, error => 'no parts', parts => 0 });
	}
	elsif (scalar @{$tabs} > 0) {
		&Websocket::send('tab', { console => &sms_mms_command($digits, $subject, \@local, $jawn_uuid) });
		# The page posts the saved MMS row's id back to /manager/sms/result. Wait
		# briefly so the sender can link that system message to the house row.
		my ($mms_id, $mms_date, $mms_thread) = (0, 0, 0);
		if ($jawn_uuid) {
			my $result_file = &subs::home('~/.shots/sms_mms_result_' . $jawn_uuid . '.json');
			for my $try ( 1 .. 25 ) {
				if (-e $result_file) {
					my $answer = eval { decode_json(scalar &read_file($result_file)) };
					if ($answer && $answer->{'mms_id'}) {
						$mms_id = $answer->{'mms_id'};
						$mms_date = $answer->{'mms_date'} || 0;
						$mms_thread = $answer->{'mms_thread'} || 0;
					}
					unlink $result_file;
					last;
				}
				select(undef, undef, undef, 0.2);
			}
		}
		$c->render(json => { ok => 1, via => 'bridge', parts => scalar @local, mms_id => $mms_id, mms_date => $mms_date, mms_thread => $mms_thread });
	}
	else {
		$c->render(json => { ok => 0, error => 'no app page open for mms', parts => scalar @local });
	}
}

# GET /manager/lorawan/settings
sub action_41040 {
	my $c = shift;
	my $s = &lorawan_public_settings($c);
	$s->{'devices'} = &lorawan_devices();
	$c->render(json => { ok => 1, %{$s} });
}

1;
