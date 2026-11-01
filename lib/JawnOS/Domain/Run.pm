package subs;

# Run: extracted from subroutines.pl (package subs). Loaded on
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

our %Y;
our $ai_eval_ready_memo;
our $ai_ledger_ready;
our $backfills_running;
our $database;
our $device;
our %error_watch_state;
our $log;
our $logfile;
our %m;
our $minion;

sub run_backfills {
	return if $backfills_running;
	$backfills_running = 1;
	my $ok = eval {
		&subs::db_query('create table if not exists backfills (name VARCHAR(255), server_time VARCHAR(255))');
		my $registry = &subs::backfills();
		my %done = map { $_->{'name'} => 1 } @{ &subs::db_query('select name from backfills')->hashes || [] };
		foreach my $name ( sort keys %{$registry} ) {
			next if $done{$name};
			my $status = eval { $registry->{$name}->() };
			if ($@) { &subs::say_it("backfill '$name' failed: $@"); next; }
			next unless $status;
			&subs::db_query('insert into backfills (name, server_time) values (?,?)', $name, &subs::rightNow());
			&subs::say_it("backfill '$name' recorded");
		}
		1;
	};
	&subs::say_it("run_backfills error: $@") if !$ok && $@;
	$backfills_running = 0;
	return $ok;
}

sub remote_deploy {
	my ($rm, %opts) = @_;
	# Deploy over http: ask the peer to pull, reinstall its desktop app and
	# restart - the same work the old ssh command did, minus ssh and the stored
	# password. remote_useragent_maker hands back the peer's tunnel-aware
	# manager url and the session cookie we already hold for it.
	my $r = eval { &subs::remote_useragent_maker({ signatorial => $rm->{'signatorial'}, rm => $rm, ip => $rm->{'ip'} }) };
	my $manager = ($r && $r->{'manager'}) || $rm->{'manager'};
	unless ($manager && $r && $r->{'ua'}) {
		return { ok => 0, message => 'no route to peer' };
	}
	my $url = $manager . '/manager/self_deploy?signatorial=' . &subs::signatorial_designer() . ($opts{'force'} ? '&force=1' : '');
	my $res = eval { $r->{'ua'}->inactivity_timeout(60)->post($url)->result };
	my $ok = ($res && $res->is_success) ? 1 : 0;
	if ($subs::logfile) {
		open(my $fh, '>>', $subs::logfile);
		print $fh &subs::rightNow() . " remote deploy " . ($rm->{'hostname'} || $rm->{'ip'}) . ": " . ($ok ? 'ok' : 'fail') . "\n";
		close $fh;
	}
	return { ok => $ok, message => $ok ? 'deployed' : 'http deploy failed', output => ($res ? $res->body : '') };
}

sub git_binary {
	return $ENV{'GIT_BINARY'} if $ENV{'GIT_BINARY'} && -x $ENV{'GIT_BINARY'};
	# the cloud runs git from a user-space install (no root)
	my $local = ($ENV{'HOME'} || '') . '/opt-git/git';
	return $local if -x $local;
	return 'git';
}

sub version_cmp {
	my ($left, $right) = @_;
	my @l = split /\./, ($left || '');
	my @r = split /\./, ($right || '');
	for my $i (0 .. 2) {
		my $x = ($l[$i] // 0) + 0;
		my $y = ($r[$i] // 0) + 0;
		return $x <=> $y if $x != $y;
	}
	return 0;
}

sub version_newer {
	my ($candidate, $mine) = @_;
	return 0 unless ($candidate || '') =~ /\d/;
	return 0 unless grep { /\d/ } split /\./, ($mine || '');
	return &subs::version_cmp($candidate, $mine) > 0 ? 1 : 0;
}

sub git_worktree_tree {
	my ($repo) = @_;
	my $git = &subs::git_binary();
	my $stash = `cd "$repo" && "$git" -c user.name=jawnos -c user.email=jawnos\@localhost stash create 2>/dev/null`;
	chomp $stash;
	return undef unless $stash =~ /^[0-9a-f]{7,40}$/;
	my $tree = `cd "$repo" && "$git" rev-parse "$stash^{tree}" 2>/dev/null`;
	chomp $tree;
	return ($tree =~ /^[0-9a-f]{40}$/) ? $tree : undef;
}

sub git_origin_has_tree {
	my ($repo, $tree) = @_;
	my $git = &subs::git_binary();
	my $trees = `cd "$repo" && "$git" log --format=%T origin/main 2>/dev/null`;
	return scalar grep { $_ eq $tree } split /\n/, $trees;
}

sub git_checkout_normalize {
	my ($opts) = @_;
	my $repo  = $opts->{'repo'} || &subs::home('~/jawnos');
	my $label = $opts->{'label'} || 'sync';
	my $git   = &subs::git_binary();
	return ('no-repo', '') unless -d "$repo/.git";
	my $dirty = `cd "$repo" && "$git" status --porcelain --untracked-files=no 2>/dev/null`;
	return ('clean', '') unless $dirty =~ /\S/;
	# best effort: with no route the synced tree is still worth preserving
	`cd "$repo" && timeout 30 "$git" fetch origin --quiet 2>/dev/null`;
	my $fetched = ($? == 0);
	my $tree = &subs::git_worktree_tree($repo);
	if ($fetched && $tree && &subs::git_origin_has_tree($repo, $tree)) {
		my $out = `cd "$repo" && "$git" reset --hard origin/main 2>&1`;
		return ('reset', $out);
	}
	my $version = &subs::jawn_version();
	my $out = `cd "$repo" && "$git" add -A 2>&1`;
	$out .= `cd "$repo" && "$git" -c user.name=JawnOS -c user.email=jawnos\@localhost commit --no-verify -m "code sync: $label ($version)" 2>&1`;
	return (($? == 0) ? 'committed' : 'dirty', $out);
}

sub git_repo_update {
	my ($opts) = @_;
	my $repo  = $opts->{'repo'} || &subs::home('~/jawnos');
	my $force = $opts->{'force'} ? 1 : 0;
	my $git   = &subs::git_binary();
	return ('no-repo', '') unless -d "$repo/.git";
	my $run = sub { my $cmd = shift; return `cd "$repo" && $cmd 2>&1`; };
	my $dirty = '';
	unless ($force) {
		# never touch a tree with local modifications to tracked files, but see
		# below: a tree whose content is already a shipped commit is not work
		$dirty = $run->("\"$git\" status --porcelain --untracked-files=no");
	}
	my $out = $run->("timeout 30 \"$git\" fetch origin --quiet");
	# a failed fetch must never be acted on: the remote-tracking ref may be
	# stale, so comparing HEAD against it could read as current (or worse, a
	# force could reset to the stale ref). error sends the watcher to its peer
	# fallback instead.
	my $fetch_ok = $? ? 0 : 1;
	if (!$force && $dirty =~ /\S/) {
		# A code sync leaves a checkout dirty with files that are part of a
		# commit origin already has (the pack excludes .git). That is not local
		# work to protect: reset to the authority instead of sitting behind.
		if ($fetch_ok) {
			my $tree = &subs::git_worktree_tree($repo);
			if ($tree && &subs::git_origin_has_tree($repo, $tree)) {
				my $reset = $run->("\"$git\" reset --hard origin/main");
				return ('reset', $dirty . $reset);
			}
		}
		return ('dirty', $dirty);
	}
	my $head   = `cd "$repo" && "$git" rev-parse HEAD 2>/dev/null`; chomp $head;
	my $origin = `cd "$repo" && "$git" rev-parse origin/main 2>/dev/null`; chomp $origin;
	return ('error', $out) unless $fetch_ok && $head && $origin;
	return ('current', $out) if $head eq $origin;
	# force makes the checkout exactly origin/main, whatever the local state
	if ($force) {
		$out .= $run->("\"$git\" reset --hard origin/main");
		return ('reset', $out);
	}
	my $behind = (system("cd \"$repo\" && \"$git\" merge-base --is-ancestor HEAD origin/main >/dev/null 2>&1") == 0);
	return ('ahead', $out) if system("cd \"$repo\" && \"$git\" merge-base --is-ancestor origin/main HEAD >/dev/null 2>&1") == 0;
	if ($behind) {
		$out .= $run->("\"$git\" merge --ff-only origin/main");
		return ('updated', $out);
	}
	# diverged and not ahead: accept it when every local commit is already
	# upstream under a rewritten hash (git cherry marks those with '-')
	my $cherry = $run->("\"$git\" cherry origin/main HEAD");
	return ('diverged', $out . $cherry) if grep { /^\+/ } split /\n/, $cherry;
	$out .= $run->("\"$git\" reset --hard origin/main");
	return ('reset', $out);
}

sub git_peer_update {
	my ($opts) = @_;
	my $repo = $opts->{'repo'} || &subs::home('~/jawnos');
	my $rm = $opts->{'rm'};
	my $git = &subs::git_binary();
	return ('no-repo', '') unless -d "$repo/.git";
	return ('no-peer', '') unless $rm;
	# never touch a tree with local modifications to tracked files
	my $dirty = '';
	$dirty = `cd "$repo" && "$git" status --porcelain --untracked-files=no 2>&1` unless $opts->{'force'};
	return ('dirty', $dirty) if $dirty =~ /\S/;
	my $head = `cd "$repo" && "$git" rev-parse HEAD 2>/dev/null`; chomp $head;
	my ($ua, $p) = &subs::peer_useragent($rm);
	return ('no-peer', '') unless $ua;
	my $url = $p->{'manager'} . '/manager/code_bundle?signatorial=' . &subs::signatorial_designer() . '&base=' . ($head || '');
	my $res = eval { $ua->inactivity_timeout(60)->get($url)->result };
	return ('peer-error', '') unless $res && $res->is_success && length($res->body || '');
	require File::Temp;
	my ($fh, $path) = File::Temp::tempfile(SUFFIX => '.bundle', UNLINK => 1);
	binmode $fh;
	print $fh $res->body;
	close $fh;
	my $fetch = `cd "$repo" && "$git" fetch "$path" HEAD 2>&1`;
	my $target = `cd "$repo" && "$git" rev-parse FETCH_HEAD 2>/dev/null`; chomp $target;
	unlink $path;
	return ('fetch-error', $fetch) unless $target;
	my $current = `cd "$repo" && "$git" rev-parse HEAD 2>/dev/null`; chomp $current;
	return ('current', '') if $current eq $target;
	if ($opts->{'force'}) {
		my $out = `cd "$repo" && "$git" reset --hard $target 2>&1`;
		return ('reset', $out);
	}
	if (system("cd \"$repo\" && \"$git\" merge-base --is-ancestor HEAD $target >/dev/null 2>&1") == 0) {
		my $out = `cd "$repo" && "$git" merge --ff-only $target 2>&1`;
		return ('updated', $out);
	}
	# a rewritten history landing on the same work (git cherry marks every local
	# commit '-') is a reset, not a conflict
	my $cherry = `cd "$repo" && "$git" cherry $target HEAD 2>&1`;
	return ('diverged', $cherry) if $opts->{'ff_only'} || grep { /^\+/ } split /\n/, $cherry;
	my $out = `cd "$repo" && "$git" reset --hard $target 2>&1`;
	return ('reset', $out);
}

sub install_extras {
	my $script = &subs::home('~/jawnos/scripts/jawnos_deps.pl');
	return unless -e $script;
	my $repo = &subs::home('~/jawnos');
	my $out = `cd "$repo" && perl scripts/jawnos_deps.pl --extras-only --install 2>&1`;
	if ($subs::logfile && defined $out && $out =~ /\S/) {
		open(my $fh, '>>', $subs::logfile);
		print $fh &subs::rightNow() . " extras: " . join(' ', grep { /\S/ } split "\n", $out) . "\n";
		close $fh;
	}
}

sub install_local_modules {
	my ($repo) = @_;
	$repo = '.' unless defined $repo && length $repo;
	return unless -f "$repo/scripts/jawnos_deps.pl";
	my $lib = &subs::home('~/perl5');
	my $out = `cd "$repo" && perl scripts/jawnos_deps.pl --local-lib "$lib" --no-extras --install 2>&1`;
	if ($subs::logfile && defined $out && $out =~ /\S/) {
		open(my $fh, '>>', $subs::logfile);
		print $fh &subs::rightNow() . " modules: " . join(' ', grep { /\S/ } split "\n", $out) . "\n";
		close $fh;
	}
}

# Ask the master to reboot the tree, saying why. A worker writes the status file
# on purpose: it is fire-and-forget, which is what a worker about to be killed by
# the restart needs, and the reason rides along into ~/.president/restart.json
# beside the guard's verdict (the master reads "restart: <reason>"). A caller
# that wants the verdict itself - an agent just after a push - runs
# scripts/restart.pl, which asks the master's control socket and waits for it.
sub restart_request {
	my ($reason) = @_;
	$reason = '' unless defined $reason;
	# one line: the status file is read as a word, not as a paragraph
	$reason =~ s/[\x00-\x1f\x7f]+/ /g;
	$reason =~ s/\s+/ /g;
	$reason =~ s/^\s+|\s+$//g;
	$reason = substr($reason, 0, 400) if length $reason > 400;
	my $line = 'restart' . (length $reason ? ': ' . $reason : '');
	write_file(&subs::home('~/.president/status'), $line);
	return $line;
}

sub error_watch_offsets_file { return &subs::home('~/.president/error_watch_offsets'); }

sub error_watch_state_load {
	my $file = &error_watch_offsets_file();
	return unless -f $file;
	my $saved = eval { decode_json scalar read_file($file) } || {};
	foreach my $source ( keys %{$saved} ) {
		next unless defined $saved->{$source} && $saved->{$source} =~ /^[0-9]+$/;
		$error_watch_state{$source} = $saved->{$source} + 0;
	}
}

sub error_watch_state_save {
	return unless %error_watch_state;
	write_file(&error_watch_offsets_file(), encode_json(\%error_watch_state));
}

sub watch_tokens_day { return localtime()->strftime('%Y-%m-%d'); }

sub watch_tokens_spent {
	# the purse is the house's: this machine's spend plus every peer's, which ride in
	# with the ordinary settings/database sync. The local cache stays as the floor,
	# so a machine with no ledger row yet never reads itself as having spent nothing.
	my $house = eval { &ai_house_budget_spent() } || 0;
	my $row = &subs::cache_get({ app => '__president', context => 'watch_tokens', subcontext => &watch_tokens_day() });
	my $local = (ref $row eq 'HASH') ? ($row->{'total'} || 0) : 0;
	return $house > $local ? $house : $local;
}

sub watch_tokens_add {
	my ($tokens) = @_;
	return unless $tokens;
	my $row = &subs::cache_get({ app => '__president', context => 'watch_tokens', subcontext => &watch_tokens_day() }) || {};
	&subs::cache_set(
		{ app => '__president', context => 'watch_tokens', subcontext => &watch_tokens_day(), warranty => '-2d' },
		{ total => ($row->{'total'} || 0) + $tokens, proposals => ($row->{'proposals'} || 0) + 1 }
	);
	# and add it to the shared purse, so every machine's ceiling sees the whole
	# house's spend and the day's budget is one pot, not one per machine
	eval { &ai_house_budget_add($tokens) };
}

sub ai_house_today { return localtime()->strftime('%Y-%m-%d'); }

sub ai_job_uuid { return 'ai_job_' . md5_sum(($_[0] // '')) }

sub ai_house_uuid { return 'ai_house_' . md5_sum(($_[0] // '')) }

sub ai_budget_uuid { return 'ai_budget_' . md5_sum(($_[0] // '') . '|' . ($_[1] // '')) }

sub ai_house_have_model {
	return ( &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'eval_assistant' }) ) ? 1 : 0;
}

sub ai_house_me { return eval { &subs::signatorial_designer() } || ''; }

sub ai_house_eval_ready {
	my $now = time;
	return $ai_eval_ready_memo->{'ready'} if $ai_eval_ready_memo && $ai_eval_ready_memo->{'at'} > $now - 60;
	my $ready = eval { &evaluation_agent_ready() } ? 1 : 0;
	$ai_eval_ready_memo = { at => $now, ready => $ready };
	return $ready;
}

sub ai_house_publish {
	my $me = &ai_house_me();
	return unless length $me;
	my $now = &subs::rightNow();
	my $have = &ai_house_have_model();
	my $row = eval { &subs::db_select('ai_house', undef, { machine => $me })->hashes->[0] };
	return if $row && ($row->{'seen'} + 0) > ($now - 120000) && (($row->{'has_model'} || 0) ? 1 : 0) == $have;
	# the evaluation needs a model it can actually reach, not merely one named in
	# the settings; publishing that is what lets the house hand the run to a
	# machine that can carry it instead of one that will answer with an error
	my $ready = $have ? &ai_house_eval_ready() : 0;
	&subs::db_delete('ai_house', { machine => $me });
	&subs::db_insert('ai_house', { uuid => &ai_house_uuid($me), machine => $me, has_model => $have, eval_ready => $ready, seen => $now, server_time => $now });
}

sub ai_house_heartbeat {
	# create the ledger once per process (the tables, their index, and the columns
	# db_insert always writes - uuid and ost - added to any table built before
	# they existed, so the ledger's own writes land)
	unless ($ai_ledger_ready) {
		foreach my $sql (
			'create table if not exists ai_house (uuid VARCHAR(255), machine VARCHAR(255) unique, has_model INT, eval_ready INT, seen VARCHAR(25), ost VARCHAR(255), server_time VARCHAR(255))',
			'create table if not exists ai_jobs (uuid VARCHAR(255), job VARCHAR(255) unique, owner VARCHAR(255), at VARCHAR(25), state VARCHAR(25), ost VARCHAR(255), server_time VARCHAR(255))',
			'create table if not exists ai_budget (uuid VARCHAR(255), machine VARCHAR(255), day VARCHAR(25), tokens INT, ost VARCHAR(255), server_time VARCHAR(255))',
			'create unique index if not exists idx_ai_budget on ai_budget (machine, day)',
			'alter table ai_house add column uuid VARCHAR(255)',
			'alter table ai_house add column ost VARCHAR(255)',
			'alter table ai_house add column eval_ready INT',
			'alter table ai_jobs add column uuid VARCHAR(255)',
			'alter table ai_jobs add column ost VARCHAR(255)',
			'alter table ai_budget add column uuid VARCHAR(255)',
			'alter table ai_budget add column ost VARCHAR(255)'
		) {
			# an ADD COLUMN already in the schema is a warning SQLite prints to
			# STDERR, not an exception; skip it so the log stays readable
			if ($sql =~ /^\s*alter\s+table\s+(\w+)\s+add\s+column\s+(\w+)/i
				&& &subs::db_query('select 1 from pragma_table_info(?) where name=?', $1, $2)->hashes->[0]) {
				next;
			}
			eval { &subs::db_query($sql) };
		}
		# give the rows already here the natural-key uuid, so a peer's next write
		# updates this row instead of colliding with the table's unique key
		eval {
			foreach my $r ( @{ &subs::db_select('ai_house', ['uuid', 'machine', 'server_time'])->hashes || [] } ) {
				my $want = &ai_house_uuid($r->{'machine'});
				&subs::db_update('ai_house', { uuid => $want, server_time => $r->{'server_time'} }, { machine => $r->{'machine'} }) if ($r->{'uuid'} // '') ne $want;
			}
			foreach my $r ( @{ &subs::db_select('ai_jobs', ['uuid', 'job', 'server_time'])->hashes || [] } ) {
				my $want = &ai_job_uuid($r->{'job'});
				&subs::db_update('ai_jobs', { uuid => $want, server_time => $r->{'server_time'} }, { job => $r->{'job'} }) if ($r->{'uuid'} // '') ne $want;
			}
			foreach my $r ( @{ &subs::db_select('ai_budget', ['uuid', 'machine', 'day', 'server_time'])->hashes || [] } ) {
				my $want = &ai_budget_uuid($r->{'machine'}, $r->{'day'});
				&subs::db_update('ai_budget', { uuid => $want, server_time => $r->{'server_time'} }, { machine => $r->{'machine'}, day => $r->{'day'} }) if ($r->{'uuid'} // '') ne $want;
			}
		};
		$ai_ledger_ready = 1;
	}
	&ai_house_publish();
}

sub ai_house_members {
	my ($need_eval) = @_;
	my $me = &ai_house_me();
	my $now = &subs::rightNow();
	my %member;
	$member{$me} = 1 if length $me && &ai_house_have_model() && (!$need_eval || &ai_house_eval_ready());
	my $rows = eval { &subs::db_select('ai_house')->hashes } || [];
	foreach my $r ( @{$rows} ) {
		next unless $r->{'machine'} && $r->{'has_model'};
		# This machine's own row is a synced copy of what its last heartbeat
		# said; the local probe above is the truth. Believing a stale self row
		# let a machine whose model had gone away keep electing itself.
		next if length $me && $r->{'machine'} eq $me;
		next if $need_eval && !$r->{'eval_ready'};
		next unless ($r->{'seen'} + 0) > ($now - 600000);
		$member{ $r->{'machine'} } = 1;
	}
	# alone: this machine is the house - but only when the job does not need
	# the evaluation model. A device with no reachable evaluation agent must
	# not be counted as a member, or it would claim the night and answer with
	# an error (or a skip) while a capable peer was never asked.
	$member{$me} = 1 if length $me && !%member && !$need_eval;
	return sort keys %member;
}

sub ai_house_servers {
	my $me = &ai_house_me();
	my %server;
	$server{$me} = 1 if length $me && (&subs::device_setter() // '') eq 'server';
	my $rows = eval { &subs::db_select('remote_machines', ['signatorial', 'device'])->hashes } || [];
	foreach my $r ( @{$rows} ) {
		next unless $r->{'signatorial'};
		$server{ $r->{'signatorial'} } = 1 if (($r->{'device'} // '') eq 'server');
	}
	return keys %server;
}

sub ai_house_machine_ready {
	my ($machine, $need_eval) = @_;
	return 0 unless defined $machine && length $machine;
	if ($machine eq &ai_house_me()) {
		return 0 unless &ai_house_have_model();
		return (!$need_eval || &ai_house_eval_ready()) ? 1 : 0;
	}
	my $now = &subs::rightNow();
	my $row = eval { &subs::db_select('ai_house', undef, { machine => $machine })->hashes->[0] };
	return 0 unless $row && $row->{'has_model'} && ($row->{'seen'} + 0) > ($now - 600000);
	return 0 if $need_eval && !$row->{'eval_ready'};
	return 1;
}

sub ai_job_rank {
	my ($job, $member) = @_;
	my $h = 5381;
	foreach my $c ( split //, ($job // '') . '|' . ($member // '') ) { $h = ( ($h * 33) + ord($c) ) % 2147483647; }
	return $h;
}

sub ai_house_dispatcher {
	my @servers = sort &ai_house_servers();
	return scalar @servers ? $servers[0] : '';
}

sub ai_house_server_known {
	my $server = &ai_house_dispatcher();
	return 0 unless length $server;
	return 1 if $server eq &ai_house_me();
	my $row = eval { &subs::db_select('ai_house', undef, { machine => $server })->hashes->[0] };
	return 0 unless $row;
	return (($row->{'seen'} + 0) > (&subs::rightNow() - 7 * 86400000)) ? 1 : 0;
}

sub ai_house_roster_size {
	my ($need_eval) = @_;
	my $me = &ai_house_me();
	my $now = &subs::rightNow();
	my %roster;
	$roster{$me} = 1 if length $me && &ai_house_have_model() && (!$need_eval || &ai_house_eval_ready());
	my $rows = eval { &subs::db_select('ai_house')->hashes } || [];
	foreach my $r ( @{$rows} ) {
		next unless $r->{'machine'} && $r->{'has_model'};
		# the local probe above is this machine's truth; a synced self row is
		# only as fresh as the last heartbeat
		next if length $me && $r->{'machine'} eq $me;
		next if $need_eval && !$r->{'eval_ready'};
		next unless ($r->{'seen'} + 0) > ($now - 7 * 86400000);
		$roster{ $r->{'machine'} } = 1;
	}
	return scalar keys %roster;
}

sub ai_house_quorum_ok {
	my ($need_eval) = @_;
	my $roster = &ai_house_roster_size($need_eval);
	return 1 unless $roster;
	my @live = &ai_house_members($need_eval);
	return (scalar(@live) * 2 > $roster) ? 1 : 0;
}

sub ai_job_runner {
	my ($job, $ttl, $need_eval, $prefer_server) = @_;
	my @house = &ai_house_members($need_eval);
	# A job that needs the evaluation model has no runner when no member can
	# reach it. Returning the local machine anyway was the old fallback, and it
	# made an unequipped device claim the run only to skip it.
	return $need_eval ? undef : &ai_house_me() unless @house;
	$ttl = 6 * 3600 * 1000 unless $ttl && $ttl > 0;
	my $now = &subs::rightNow();
	my $rows = eval { &subs::db_select('ai_jobs', undef, { job => $job })->hashes } || [];
	foreach my $r ( @{$rows} ) {
		my $at = ($r->{'at'} || 0) + 0;
		next unless $at && ($now - $at) <= $ttl;
		my $state = $r->{'state'} || 'ran';
		if ($state eq 'claimed' || $state eq 'running') {
			next unless ($now - $at) <= 30 * 60 * 1000;   # an expired claim is free
			my $owner = $r->{'owner'} || '';
			next if length $owner && !grep { $_ eq $owner } @house;   # the claimant is gone
		}
		return undef;   # a live machine has this job covered
	}
	my @ranked = sort { &ai_job_rank($job, $a) <=> &ai_job_rank($job, $b) } @house;
	if ($prefer_server) {
		my %server = map { $_ => 1 } &ai_house_servers();
		my @servers = grep { $server{$_} } @ranked;
		return $servers[0] if scalar @servers;
	}
	return $ranked[0];
}

sub ai_job_claim {
	my ($job) = @_;
	return 0 unless length($job // '');
	my $now = &subs::rightNow();
	eval { &subs::db_delete('ai_jobs', { job => $job }) };
	eval { &subs::db_insert('ai_jobs', { uuid => &ai_job_uuid($job), job => $job, owner => &ai_house_me(), at => $now, state => 'running', server_time => $now }) };
	return 1;
}

sub ai_job_boot_ms {
	my $file = &subs::home('~/.president/on_duty');
	my $v = -e $file ? eval { read_file($file) } : '';
	$v = '' unless defined $v;
	$v =~ s/\s+//g;
	return ($v =~ /^\d{10,}$/) ? $v + 0 : 0;
}

sub ai_job_own_claim {
	my ($job, $me) = @_;
	return 0 unless length($job // '') && length($me // '');
	my $row = eval { &subs::db_select('ai_jobs', undef, { job => $job })->hashes->[0] };
	return 0 unless $row;
	return 0 unless (($row->{'owner'} // '') eq $me) && (($row->{'state'} // '') eq 'running');
	return 0 unless (($row->{'at'} || 0) + 0) > (&subs::rightNow() - 30 * 60 * 1000);
	&ai_job_claim($job);
	return 1;
}

sub ai_job_may_run {
	my ($job, $ttl, $need_eval, $prefer_server) = @_;
	return 1 unless length($job // '');
	my $runner = &ai_job_runner($job, $ttl, $need_eval, $prefer_server);
	return 0 unless defined $runner;
	return 0 unless $runner eq &ai_house_me();
	&ai_job_claim($job);
	return 1;
}

sub ai_job_note {
	my ($job) = @_;
	return unless length($job // '');
	my $now = &subs::rightNow();
	eval { &subs::db_delete('ai_jobs', { job => $job }) };
	eval { &subs::db_insert('ai_jobs', { uuid => &ai_job_uuid($job), job => $job, owner => &ai_house_me(), at => $now, state => 'ran', server_time => $now }) };
}

sub evaluation_schedule_ms {
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	return ($text + 0) * 1000 if $text =~ /^\d+$/;
	return 0 unless $text =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/;
	my $epoch = eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
	return defined $epoch ? $epoch * 1000 : 0;
}

sub ai_job_dispatch_claim {
	my ($job) = @_;
	my $me = &ai_house_me();
	return 0 unless length($job // '') && length $me;
	# two jobs can be queued for the same assignment (the cron and the dispatch
	# tick); the lock makes the claim a single step so only one of them runs
	my $minion = &subs::minion_grabber();
	return 0 unless $minion->lock('evaluation_claim_' . $job, 60);
	my $row = eval { &subs::db_select('ai_jobs', undef, { job => $job })->hashes->[0] };
	return 0 unless $row;
	return 0 unless (($row->{'owner'} // '') eq $me);
	my $state = $row->{'state'} || '';
	my $now = &subs::rightNow();
	my $at = ($row->{'at'} || 0) + 0;
	return 0 if $state eq 'ran' || $state eq 'failed';
	return 0 unless $state eq 'dispatched' || $state eq 'running';
	return 0 if !$at || ($now - $at) > 30 * 60 * 1000;
	return 0 if $state eq 'running' && ($now - $at) <= 30 * 60 * 1000;
	eval { &subs::db_delete('ai_jobs', { job => $job }) };
	eval { &subs::db_insert('ai_jobs', { uuid => &ai_job_uuid($job), job => $job, owner => $me, at => $now, state => 'running', server_time => $now }) };
	return 1;
}

sub evaluation_dispatch_sweep {
	my $me = &ai_house_me();
	my $server = &ai_house_dispatcher();
	return 0 unless length $server && $server eq $me;
	my $listed = eval { &subs::minion_grabber()->list_schedules(0, 1000) } || {};
	my @ready = &ai_house_members(1);
	my %ready = map { $_ => 1 } @ready;
	my $named = &subs::evaluation_machine();
	my $now = &subs::rightNow();
	my $lead = 10 * 60 * 1000;
	my $guard = 30 * 60 * 1000;
	my $count = 0;
	foreach my $sch ( @{ $listed->{'schedules'} || [] } ) {
		next unless ($sch->{'name'} // '') =~ /^nightly_evaluation_(.+)$/;
		my $app = $1;
		next if $sch->{'paused'};
		my $due = &evaluation_schedule_ms($sch->{'next_run'});
		next unless $due > $now && $due <= $now + $lead;
		my $key = 'eval:' . $app;
		my $existing = eval { &subs::db_select('ai_jobs', undef, { job => $key })->hashes->[0] };
		next if $existing && (($existing->{'at'} || 0) + 0) > ($now - $guard);
		# the server dispatches to a mobile/computer when one is ready; it runs
		# the report itself only when no worker can
		my @workers = grep { $_ ne $me } @ready;
		my $owner;
		if ($named && $named ne $me && $ready{$named}) { $owner = $named; }
		elsif (@workers) {
			$owner = (sort { &ai_job_rank($key, $a) <=> &ai_job_rank($key, $b) } @workers)[0];
		}
		elsif (&ai_house_eval_ready()) { $owner = $me; }
		else { next; }
		eval {
			&subs::db_delete('ai_jobs', { job => $key });
			&subs::db_insert('ai_jobs', { uuid => &ai_job_uuid($key), job => $key, owner => $owner, at => $now, state => 'dispatched', server_time => $now });
		};
		$count++;
	}
	return $count;
}

sub evaluation_dispatch_tick {
	my $me = &ai_house_me();
	return 0 unless length $me;
	if (&ai_house_dispatcher() eq $me) {
		eval { &evaluation_dispatch_sweep() };
	}
	return 0 unless &ai_house_server_known();
	my $now = &subs::rightNow();
	my $rows = eval { &subs::db_query("select job, at from ai_jobs where job like ? and owner = ? and state = ?", 'eval:%', $me, 'dispatched')->hashes } || [];
	my $minion = &subs::minion_grabber();
	foreach my $r ( @{$rows} ) {
		next unless (($r->{'at'} || 0) + 0) > ($now - 30 * 60 * 1000);
		my ($app) = ($r->{'job'} // '') =~ /^eval:(.+)$/;
		next unless $app;
		next unless $minion->lock('evaluation_dispatch_' . $app, 120);
		$minion->enqueue('appointment_evaluation' => [ { app => $app } ] => { attempts => 2 });
	}
	return 1;
}

sub ai_house_budget_spent {
	my $row = eval { &subs::db_query('select sum(tokens) as total from ai_budget where day = ?', &ai_house_today())->hashes->[0] };
	return ($row && defined $row->{'total'}) ? ($row->{'total'} + 0) : 0;
}

sub ai_house_budget_add {
	my ($n) = @_;
	return unless $n;
	my $me = &ai_house_me() || 'me';
	my $day = &ai_house_today();
	# one row per machine per day, so two machines' writes never clobber each other
	# and the sync just adds them up
	my $row = eval { &subs::db_select('ai_budget', undef, { machine => $me, day => $day })->hashes->[0] };
	my $total = (($row && $row->{'tokens'}) ? $row->{'tokens'} : 0) + $n;
	&subs::db_delete('ai_budget', { machine => $me, day => $day });
	&subs::db_insert('ai_budget', { uuid => &ai_budget_uuid($me, $day), machine => $me, day => $day, tokens => $total, server_time => &subs::rightNow() });
	return $total;
}

1;
