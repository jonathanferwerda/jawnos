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
# Whether this machine can reach the model the evaluation is configured to use.
# The setting is shared but the reach is local: an ollama that is not running or a
# key that was never entered makes a machine a poor home for the night's run.
# Memoised for a minute so the heartbeat and a job do not probe twice.
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

# ---------------------------------------------------------------------------
# Auto-update. A machine that receives code by git can keep itself current: the
# watcher fetches origin and fast-forwards when the tree is clean and strictly
# behind (never clobbers local commits or a dirty tree), then asks jawn to
# restart. When the tree is clean but diverged because origin's history was
# rewritten (every local commit still exists upstream under a new hash), it
# resets hard to origin/main so the machine rejoins the update track; a tree
# with genuinely local commits is left alone. Open browsers reload on their own:
# the websocket hands out the revision and the client reloads when it changes.
# ---------------------------------------------------------------------------
# Push the current code to a neighbour over ssh, using the credentials the
# remote_machines table already holds. Every device can also pull on its own
# (git_watcher_check), so this is the "force it now" lever: fast-forward the
# repo, reinstall the desktop app where one is installed, and ask jawn to
# restart. Returns { ok, message, output }.
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

# Fast-forward a checkout to origin/main. Returns (status, output):
#   current   already up to date
#   updated   fast-forwarded to origin/main
#   ahead     has commits origin/main does not; left alone
#   reset     diverged, but every local commit already exists upstream under a
#             rewritten hash, so reset hard to origin/main (nothing unique lost)
#   diverged  has local commits that are not upstream; left alone (use force)
#   dirty     tracked files are modified; never touched (use force)
#   error     the fetch failed (no route, bad credentials) or the checkout
#             could not be read; nothing was moved
#   no-repo   not a git checkout
# A clean tree only, unless force, which skips the dirty guard and hard-resets.
# Which of two dotted versions is newer - numerically, so 0.1.112 beats 0.1.79
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

# Whether a reset target would put older code on this machine. A reset is a
# repair, not a downgrade: every push bumps VERSION, so a target that sorts
# below HEAD's is older whatever the commit graph says - a rewritten origin, a
# stale fetch, or a peer whose advertised version outran its actual tree. The
# fast-forward paths never ask: a true descendant is always the newer tree. An
# unreadable VERSION on either side keeps the old behaviour.
my $target_is_older = sub {
	my ($repo, $target) = @_;
	return 0 unless defined $target && $target =~ /^[A-Za-z0-9_.\/^~-]+$/;
	my $git = &subs::git_binary();
	my $at = sub {
		my $v = `cd "$repo" && "$git" show "$_[0]:VERSION" 2>/dev/null`;
		chomp $v;
		return ($v =~ /\d/) ? $v : '';
	};
	my $mine   = $at->('HEAD');
	my $theirs = $at->($target);
	return 0 unless length $mine && length $theirs;
	return &subs::version_cmp($theirs, $mine) < 0 ? 1 : 0;
};

# Whether the working tree's VERSION is older than HEAD's - the code-sync case,
# where a peer's files are laid over the checkout and no commit names them yet.
# An unreadable VERSION on either side keeps the old behaviour.
my $worktree_is_older = sub {
	my ($repo) = @_;
	my $git = &subs::git_binary();
	my $theirs = '';
	if (open(my $fh, '<', "$repo/VERSION")) {
		$theirs = do { local $/; <$fh> } // '';
		close $fh;
		$theirs =~ s/\s+//g;
		$theirs = '' unless $theirs =~ /\d/;
	}
	my $mine = `cd "$repo" && "$git" show HEAD:VERSION 2>/dev/null`;
	chomp $mine;
	$mine =~ s/\s+//g;
	return 0 unless length $mine && length $theirs;
	return &subs::version_cmp($theirs, $mine) < 0 ? 1 : 0;
};

# A refused reset is logged once, not every tick: the version pair names the
# reason, and repeats of the same pair stay quiet.
my $rollback_refused_note = '';
my $rollback_refused = sub {
	my ($repo, $target, $source) = @_;
	return unless $subs::logfile;
	my $git = &subs::git_binary();
	my $at = sub {
		my $v = `cd "$repo" && "$git" show "$_[0]:VERSION" 2>/dev/null`;
		chomp $v;
		$v =~ s/\s+//g;
		return ($v =~ /\d/) ? $v : '';
	};
	my $mine   = $at->('HEAD');
	my $theirs = $at->($target);
	my $note = join ' ', $source, $target, $theirs, $mine;
	return if $rollback_refused_note eq $note;
	$rollback_refused_note = $note;
	open(my $fh, '>>', $subs::logfile) or return;
	print $fh &subs::rightNow() . " $source: refused to reset to $target"
		. (length $mine && length $theirs ? " ($theirs is older than HEAD $mine)" : '')
		. "; left the checkout at HEAD\n";
	close $fh;
	return;
};

# The tree the working files would commit as, without touching the worktree or
# the index. A code sync writes a peer's files over a checkout, so this is what
# a commit would carry - and what can be compared with the commits origin knows.
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

# Whether origin/main's history already carries this exact tree.
sub git_origin_has_tree {
	my ($repo, $tree) = @_;
	my $git = &subs::git_binary();
	my $trees = `cd "$repo" && "$git" log --format=%T origin/main 2>/dev/null`;
	return scalar grep { $_ eq $tree } split /\n/, $trees;
}

# A code sync writes a peer's tree over a checkout (the pack excludes .git), so
# every synced file reads as modified against a stale HEAD. Put the checkout back
# in a state git can move: if the synced tree is a shipped commit, reset to
# origin/main; otherwise preserve it as a local commit, so the work is not lost
# and the tree is clean for the next pull. No git, nothing to do.
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
		# The synced files may be an older peer's tree laid over a newer checkout.
		# Follow the authority when it advanced; otherwise reset to HEAD, which
		# cleans the tree without putting older code back on the machine.
		my $older = $target_is_older->($repo, 'origin/main');
		$rollback_refused->($repo, 'origin/main', 'code sync') if $older;
		my $target = $older ? 'HEAD' : 'origin/main';
		my $out = `cd "$repo" && "$git" reset --hard $target 2>&1`;
		return ('reset', $out);
	}
	# With no route to origin, a peer's older tree is all there is to inspect. It
	# must not be committed over newer code: that would move the checkout
	# backwards without a reset for anyone to notice. Restore HEAD and say why.
	if ($worktree_is_older->($repo)) {
		my $synced = '';
		if (open(my $fh, '<', "$repo/VERSION")) { $synced = do { local $/; <$fh> } // ''; close $fh }
		$synced =~ s/\s+//g;
		my $out = `cd "$repo" && "$git" reset --hard HEAD 2>&1`;
		if ($subs::logfile) {
			open(my $fh, '>>', $subs::logfile);
			print $fh &subs::rightNow() . " code sync: the synced tree"
				. (length $synced ? " ($synced)" : '') . " is older than HEAD; restored HEAD\n";
			close $fh;
		}
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
				# Same rule as the code-sync normalize: restore HEAD when origin is
				# behind, so a synced tree cannot drag the checkout backwards.
				my $older = $target_is_older->($repo, 'origin/main');
				$rollback_refused->($repo, 'origin/main', 'git update') if $older;
				my $target = $older ? 'HEAD' : 'origin/main';
				my $reset = $run->("\"$git\" reset --hard $target");
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
		if ($target_is_older->($repo, 'origin/main')) {
			$rollback_refused->($repo, 'origin/main', 'forced update');
			return ('ahead', $out);
		}
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
	if ($target_is_older->($repo, 'origin/main')) {
		$rollback_refused->($repo, 'origin/main', 'git update');
		return ('diverged', $out . $cherry);
	}
	$out .= $run->("\"$git\" reset --hard origin/main");
	return ('reset', $out);
}

# Pull the code from a peer: it hands back a git bundle of its own HEAD (a
# delta since ours when it can), we fetch it and fast-forward or reset by the
# same rules as a pull from origin. This is the watcher's fallback for a machine
# with no route to GitHub. ff_only also refuses the reset case: the fallback
# must never move a tree anywhere a fast-forward cannot reach, or a peer whose
# advertised version outran its actual tree can drag a machine backward (the
# rewritten-history reset once did, under "whoever has the newest is it").
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
	my $fetch_ok = ($? == 0);
	my $target = `cd "$repo" && "$git" rev-parse FETCH_HEAD 2>/dev/null`; chomp $target;
	unlink $path;
	# A failed fetch leaves the previous FETCH_HEAD in place, so the target above
	# can be an older bundle from an earlier run. Never act on it.
	return ('fetch-error', $fetch) unless $fetch_ok && $target;
	my $current = `cd "$repo" && "$git" rev-parse HEAD 2>/dev/null`; chomp $current;
	return ('current', '') if $current eq $target;
	if ($opts->{'force'}) {
		if ($target_is_older->($repo, $target)) {
			$rollback_refused->($repo, $target, 'peer update');
			return ('diverged', 'the peer tree is older than this checkout');
		}
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
	if ($target_is_older->($repo, $target)) {
		$rollback_refused->($repo, $target, 'peer update');
		return ('diverged', 'the peer tree is older than this checkout');
	}
	my $out = `cd "$repo" && "$git" reset --hard $target 2>&1`;
	return ('reset', $out);
}

# Best-effort, idempotent install of the optional applications the tree names
# (scripts/jawnos_deps.pl's extras: Piper today). Called after a code update so a
# new version's new apps land without a hand; a device that cannot install one
# simply keeps the fallback.
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

# New versions name new Perl modules, and the image's system Perl only has the
# ones it shipped with. A pull cannot install system packages as the person who
# runs the app, so the modules go in ~/perl5 - the local::lib `jawn` already
# puts on @INC, which lives on the state partition and therefore survives a
# reboot. Best effort: a failure is logged and the code update stands.
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

# The offsets live in a little file so a President restart (which happens on
# every code change) does not re-read the whole pty log and count every fault
# again; ~/.president is wiped when the master starts, so they never outlive the
# pty log they describe.
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

# The watch's purse: what today's proposals have cost, kept in the local cache
# (cache is never synced or backed up), so the day's budget can stop it before
# a runaway spend. The ceiling is the error_watch_budget setting (tokens/day;
# unset means a 1,000,000-a-day default, and 0 means no ceiling).
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

# ---- the house AI ledger -----------------------------------------------------
# One machine runs each AI job, and the day's purse is shared. A "job" is a unit
# of work with a name: an error's fix, an app's evaluation. Ownership is
# deterministic - a stable hash ranks the house and the job's home is the member
# ranked first - so every machine computes the same home with no lock service and
# no shared write to race. Only the home's own watcher proposes a given fix or
# runs a given evaluation.
#
# Eligibility rides the same synced tables: each machine publishes its own row
# (does it have an AI model, when it was last seen) and its own day's spend. The
# house is the members whose row says they have a model and were seen recently;
# a machine with nothing synced yet sees only itself, so it still works alone.
sub ai_house_today { return localtime()->strftime('%Y-%m-%d'); }

# The ledger's rows are keyed by a natural name (a job, a machine, a machine's
# day) but the sync matches rows by uuid. A fresh random uuid on every write
# meant a peer never recognised the update, and the table's unique key then
# refused the insert, so the ledger froze at each machine's first row. A uuid
# derived from the natural key is stable, so the sync updates the row it holds.
sub ai_job_uuid { return 'ai_job_' . md5_sum(($_[0] // '')) }

sub ai_house_uuid { return 'ai_house_' . md5_sum(($_[0] // '')) }

sub ai_budget_uuid { return 'ai_budget_' . md5_sum(($_[0] // '') . '|' . ($_[1] // '')) }

# The audit's natural key: one row per machine, even after a peer syncs it.
sub where_audit_uuid { return 'where_audit_' . md5_sum(($_[0] // '')) }

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

# The machines that can take AI work: those that published a model and were seen
# in the last ten minutes, plus this machine (so a lone or not-yet-synced machine
# is never left with nobody). When $need_eval is set the machine must also reach
# the evaluation's model. Sorted, so every machine ranks the same house.
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

# The house's servers, by signatorial. A server is the machine most likely to be
# awake and reachable, so it is asked to carry the evaluation before the rest.
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

# Whether a named machine can take the work now. The local machine is asked
# directly (its heartbeat may be this very process's); a peer is judged by the
# row it synced, so a machine that has gone quiet is not believed.
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

# The machine that dispatches scheduled evaluations: a server, when the house
# has one. Several servers would choose the same one because the list is sorted.
sub ai_house_dispatcher {
	my @servers = sort &ai_house_servers();
	return scalar @servers ? $servers[0] : '';
}

# On a worker, "the server is known" means the server has published a heartbeat
# under this code and has been seen within the week. A server that is merely
# listed in remote_machines but has not upgraded yet is ignored, so a rolling
# update does not stop the first morning; a server gone for longer than the
# week is no longer a dispatcher, and the house falls back to quorum.
sub ai_house_server_known {
	my $server = &ai_house_dispatcher();
	return 0 unless length $server;
	return 1 if $server eq &ai_house_me();
	my $row = eval { &subs::db_select('ai_house', undef, { machine => $server })->hashes->[0] };
	return 0 unless $row;
	return (($row->{'seen'} + 0) > (&subs::rightNow() - 7 * 86400000)) ? 1 : 0;
}

# The roster a serverless house uses for quorum: the AI-capable machines seen
# within a week, plus this machine. A machine gone for longer than that has left
# the house and no longer holds a vote.
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

# A strict majority of the roster must be present. A one-machine house is its
# own majority; a minority partition stands down instead of running the report a
# second time.
sub ai_house_quorum_ok {
	my ($need_eval) = @_;
	my $roster = &ai_house_roster_size($need_eval);
	return 1 unless $roster;
	my @live = &ai_house_members($need_eval);
	return (scalar(@live) * 2 > $roster) ? 1 : 0;
}

# The machine that runs $job now. The present house - the machines whose model
# heartbeat is fresh - is ranked by the job's own order, and if nobody has run
# the job within $ttl the highest-ranked member takes it. Because the house holds
# only machines seen recently, a home that goes quiet drops out and the job falls
# to the next machine (the failover); a job already run within the ttl is left
# alone by everyone, so a machine that runs it and then goes quiet does not cause
# a second run.
#
# A claim (state 'running' or 'claimed') is a lease rather than a fact: it covers
# the job for half an hour, and only while its owner is still among the living.
# A machine that claimed a run and then vanished therefore hands the work on
# instead of holding it forever.
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

# Write the claim before the work starts. A peer that reads the ledger sees a job
# already spoken for, so two machines never pay for the same evaluation; a claim
# left by a machine that goes quiet expires (see ai_job_runner), so the house can
# take the work back.
sub ai_job_claim {
	my ($job) = @_;
	return 0 unless length($job // '');
	my $now = &subs::rightNow();
	eval { &subs::db_delete('ai_jobs', { job => $job }) };
	eval { &subs::db_insert('ai_jobs', { uuid => &ai_job_uuid($job), job => $job, owner => &ai_house_me(), at => $now, state => 'running', server_time => $now }) };
	return 1;
}

# The moment this manager booted, in ms. A claim older than this cannot belong
# to a live process: every worker was restarted after it was written.
sub ai_job_boot_ms {
	my $file = &subs::home('~/.president/on_duty');
	my $v = -e $file ? eval { read_file($file) } : '';
	$v = '' unless defined $v;
	$v =~ s/\s+//g;
	return ($v =~ /^\d{10,}$/) ? $v + 0 : 0;
}

# A retry of a job this machine already claimed: the previous attempt died
# before it could settle, and the queue runs one job at a time, so the claim
# cannot belong to a live attempt here. A peer still sees the claim as live,
# which is why the retry takes it back explicitly rather than through the
# election (that could elect the peer and deadlock on this very row).
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

# May this machine run $job? Only when it is the job's runner. The claim is
# written here, before the caller spends anything, so the rest of the house sees
# the intent at once; ai_job_note marks it finished afterwards.
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

# ---- evaluation dispatch ----------------------------------------------------
# The server is the dispatcher; a mobile or computer is a worker. The dispatcher
# assigns each scheduled run to one ready worker a few minutes before it is due,
# and a worker only runs what is addressed to it. A partition that cannot see
# the server receives no fresh assignment and stands down, which is what keeps a
# split house from running the same report twice. A house with no server at all
# elects by quorum instead.

# Minion lists schedules with next_run as epoch seconds; a stored string form
# is accepted too when a caller reads the row directly.
sub evaluation_schedule_ms {
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	return ($text + 0) * 1000 if $text =~ /^\d+$/;
	return 0 unless $text =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/;
	my $epoch = eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
	return defined $epoch ? $epoch * 1000 : 0;
}

# A worker claims the server's assignment. Only the addressed machine may take
# it, only while it is fresh, and only once: 'running' is the claim, 'ran' the
# receipt. A stale claim can be taken over, so a worker that dies mid-run does
# not hold the job forever.
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

# The dispatcher's half: look at the schedules due in the next ten minutes and
# write one assignment per run. An assignment still in flight is left alone, so
# a run is never handed to a second machine while the first holds it.
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

# Every machine's minute: the server writes the assignments, and every machine
# turns an assignment addressed to it into a queued job. Using the tick rather
# than the cron means an assignment that reaches a worker a few seconds late is
# still picked up on the next minute instead of waiting for the next cadence.
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

# the shared purse: what the whole house has spent today
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

# The clock minute a reading belongs to, in this machine's own time, as the
# sortable key 'YYYY-MM-DD HH:MM'. The balance chart's bars are local clock
# minutes, so the token ledger must count in the same keys or the two would be
# offset.
sub ai_spend_minute_key {
	my ($ms) = @_;
	$ms = &subs::rightNow() unless defined $ms && $ms =~ /^-?\d+$/;
	my $t = localtime($ms / 1000);
	return ref $t ? $t->strftime('%Y-%m-%d %H:%M') : '';
}

# Every model call banks its usage here as its own row: the minute it ran, the
# model and the role that asked for it. One row per call - a second call in the
# same minute is a new row, because the chart's job is to show the traffic that
# caused a fall, not to merge it away. The ledger carries server_time, so it
# rides the ordinary sync: the balance an account falls by is the house's spend,
# and the tokens beside it must be the house's too. A call that reports no usage
# writes nothing rather than a zero. A database problem must never take an AI
# call down, so the write is guarded and only a failure is logged.
sub ai_spend_note {
	my ($provider, $in, $out, $model, $role) = @_;
	$in = (defined $in && $in =~ /^\d+$/) ? ($in + 0) : 0;
	$out = (defined $out && $out =~ /^\d+$/) ? ($out + 0) : 0;
	return 0 unless $in || $out;
	$provider = '' unless defined $provider;
	$model = '' unless defined $model;
	$role = '' unless defined $role;
	my $ok = eval {
		&subs::db_insert('ai_spend', {
			machine => (&ai_house_me() || 'me'),
			provider => $provider,
			model => $model,
			role => $role,
			minute => &ai_spend_minute_key(),
			tokens_in => $in,
			tokens_out => $out,
			calls => 1,
			server_time => &subs::rightNow(),
		});
	};
	unless ($ok) {
		my $why = $@ ? ($@ =~ s/\s+/ /gr) : 'the row was not written';
		eval { &subs::log_writer('ai_spend note failed: ' . $why) };
		return 0;
	}
	return 1;
}

# Today's locator use, from the rows where.pl writes. A miss is the number that
# matters - it is the lookup that sends an agent back to grep - so the panel can
# show the rate. An absent table (a database that has not migrated yet) reads as
# no calls rather than taking the panel down.
sub where_lookup_stats {
	my ($since_key) = @_;
	$since_key = '' unless defined $since_key;
	my $row = eval {
		&subs::db_query(
			'select count(*) as calls,'
			. ' sum(case when hit > 0 then 1 else 0 end) as hits,'
			. ' sum(case when hit = 0 then 1 else 0 end) as misses'
			. ' from where_calls where minute >= ?', $since_key)->hashes->[0];
	};
	my $feedback = eval {
		&subs::db_query(
			"select sum(case when verdict = 'right' then 1 else 0 end) as right,"
			. " sum(case when verdict in ('wrong','miss') then 1 else 0 end) as wrong"
			. ' from where_feedback where minute >= ?', $since_key)->hashes->[0];
	};
	return {
		calls  => ($row && $row->{'calls'}  || 0) + 0,
		hits   => ($row && $row->{'hits'}   || 0) + 0,
		misses => ($row && $row->{'misses'} || 0) + 0,
		right  => ($feedback && $feedback->{'right'} || 0) + 0,
		wrong  => ($feedback && $feedback->{'wrong'} || 0) + 0,
	};
}

# The locator audit, on the same settings pattern as the evaluation: a cadence
# in the house settings, a run-now button, and a report kept in the synced
# `where_audit` table. The window is since the last successful run (with a
# one-minute overlap so a row written while the audit runs is never skipped);
# the first run reads the script's default 14 days.
# The report used to live in the cache, which is machine-local and deliberately
# never synced, so a laptop could not see a run made on the desktop. The table
# carries server_time, which is what lets it ride the ordinary peer sync; one
# row per machine means a peer's newer report is shown without replacing the
# other machine's copy.
# The master switch for the scheduled audit, separate from the cadence: off
# pauses the butler without losing the frequency, and the Run now button still
# works. The per-lookup ledger keeps recording; this gates the audit only.
sub where_audit_enabled {
	my $v = &subs::setting_grabber({ app => '__president', setting => 'where_audit_enabled' });
	return 1 unless defined $v && length $v;
	return 0 if $v =~ /^(?:0|off|no|false|disabled)$/i;
	return 1;
}

sub where_audit_cadence {
	my $c = &subs::setting_grabber({ app => '__president', setting => 'where_audit_cadence' });
	return $c if defined $c && grep { $_ eq $c } qw/off hourly daily weekly monthly yearly/;
	return 'off';
}

sub where_audit_interval {
	my ($cadence) = @_;
	$cadence = '' unless defined $cadence;
	return 3600 * 1000 if $cadence eq 'hourly';
	return 86400 * 1000 if $cadence eq 'daily';
	return 7 * 86400000 if $cadence eq 'weekly';
	return 30 * 86400000 if $cadence eq 'monthly';
	return 365 * 86400000 if $cadence eq 'yearly';
	return 0;
}

sub where_audit_report {
	my $row = eval {
		&subs::db_query(
			'select machine, report from where_audit'
			. ' order by cast(server_time as integer) desc, cast(at as integer) desc limit 1'
		)->hashes->[0];
	};
	return {} unless $row && defined $row->{'report'} && length $row->{'report'};
	my $report = eval { decode_json($row->{'report'}) };
	return {} unless ref $report eq 'HASH';
	$report->{'machine'} = $row->{'machine'} if defined $row->{'machine'} && length $row->{'machine'};
	return $report;
}

# Store a report as this machine's row. Update in place: delete-then-insert
# would drop the report if the insert failed, and the natural-key uuid already
# identifies the row a peer synced. The server_time stamp is what the sync uses
# to pick the newer report from another machine.
sub where_audit_bank {
	my ($report) = @_;
	return 0 unless ref $report eq 'HASH';
	my $me   = &ai_house_me() || 'me';
	my $uuid = &where_audit_uuid($me);
	my $value = {
		machine     => $me,
		at          => $report->{'at'} || 0,
		report      => encode_json($report),
		server_time => &subs::rightNow(),
	};
	my $ok = eval {
		my $found = &subs::db_select('where_audit', ['uuid'], { uuid => $uuid })->hashes->[0];
		if ($found && $found->{'uuid'}) {
			&subs::db_update('where_audit', $value, { uuid => $uuid });
		}
		else {
			&subs::db_insert('where_audit', { %{$value}, uuid => $uuid });
		}
		1;
	};
	return $ok ? 1 : 0;
}

sub where_audit_next {
	return 0 unless &where_audit_enabled();
	my $interval = &where_audit_interval(&where_audit_cadence());
	return 0 unless $interval;
	my $at = (&where_audit_report()->{'at'} || 0) + 0;
	return $at ? $at + $interval : 0;
}

sub where_audit_due {
	return 0 unless &where_audit_enabled();
	my $interval = &where_audit_interval(&where_audit_cadence());
	return 0 unless $interval;
	my $report  = &where_audit_report();
	my $at      = ($report->{'at'} || 0) + 0;
	my $attempt = ($report->{'attempt'} || 0) + 0;
	my $now     = &subs::rightNow();
	# A failed run leaves `at` where it was; the attempt marker keeps the tick
	# from retrying a broken script every minute.
	return 0 if $attempt && !$report->{'ok'} && ($now - $attempt) < 5 * 60 * 1000;
	return 1 unless $at;
	return $now >= $at + $interval ? 1 : 0;
}

sub where_audit_tick {
	return 0 unless &where_audit_due();
	return 0 unless &ai_house_dispatcher() eq &ai_house_me();
	return &where_audit_run({ reason => 'schedule' }) ? 1 : 0;
}

sub where_audit_run {
	my ($opt) = @_;
	$opt = {} unless ref $opt eq 'HASH';
	my $now    = &subs::rightNow();
	my $minion = eval { &subs::minion_grabber() };
	return 0 unless $minion && $minion->lock('where_audit_run', 120);

	# The lock is a guard against a hung run, not a cooldown: release it as soon
	# as the run finishes so the button works again at once.
	my $finish = sub {
		my ($result) = @_;
		eval { $minion->unlock('where_audit_run') };
		return $result;
	};

	my $previous = &where_audit_report();
	my $repo     = &subs::home('~/jawnos');
	my $script   = "$repo/scripts/where_audit.pl";
	my $fail     = sub {
		my ($why) = @_;
		&where_audit_bank({ %{$previous}, attempt => $now, ok => 0, error => $why });
		return 0;
	};
	return $finish->($fail->('the checkout has no scripts/where_audit.pl')) unless -f $script;

	my @args = ('--json');
	my $last = ($previous->{'at'} || 0) + 0;
	push @args, '--since', &ai_spend_minute_key($last - 60_000) if $last;

	my ($out, $code) = ('', 1);
	eval {
		open(my $fh, '-|', $^X, $script, @args) or die "open: $!\n";
		local $/;
		$out = <$fh> // '';
		close $fh;
		$code = $? >> 8;
		1;
	} or return $finish->($fail->('the audit could not start'));
	return $finish->($fail->('the audit did not return a report')) if $code != 0;

	my $data = eval { JSON::PP->new->utf8->decode($out) };
	return $finish->($fail->('the audit returned invalid JSON')) unless ref $data eq 'HASH';

	$data->{'at'}      = $now;
	$data->{'attempt'} = $now;
	$data->{'ok'}      = 1;
	$data->{'reason'}  = $opt->{'reason'} || 'manual';
	delete $data->{'error'};
	my $banked = &where_audit_bank($data);
	&subs::log_writer('where audit: the report could not be banked') unless $banked;
	return $finish->($banked ? 1 : 0);
}

# The ledger summed per provider in the granularity the caller asks for: '2m'
# (an even-minute bucket, folded here), 'hour' or 'day' (a prefix of the minute
# key, grouped by SQLite). `$since_key` is the earliest minute key to count;
# everything older is left out. The shape is
# provider -> bucket -> { tokens, calls, models -> { model -> tokens } }. An
# absent table (a database that has not migrated yet) reads as no tokens rather
# than taking the panel down.
sub ai_spend_buckets {
	my ($granularity, $since_key) = @_;
	$granularity = 'hour' unless defined $granularity && $granularity =~ /^(?:2m|hour|day)$/;
	$since_key = '' unless defined $since_key;
	my $key_sql = $granularity eq '2m' ? 'minute as k'
		: $granularity eq 'day' ? 'substr(minute, 1, 10) as k'
		: 'substr(minute, 1, 13) as k';
	my $rows = eval {
		&subs::db_query('select provider, model, ' . $key_sql . ', sum(tokens_in + tokens_out) as tokens, count(*) as calls from ai_spend where minute >= ? group by provider, model, k', $since_key)->hashes;
	} || [];
	my %map;
	foreach my $r ( @{$rows} ) {
		my $key = $r->{'k'} // '';
		next unless length $key;
		if ($granularity eq '2m') {
			# 'YYYY-MM-DD HH:MM' floored to an even minute: MM - MM % 2
			my $mm = substr($key, 14, 2);
			next unless $mm =~ /^\d{2}$/;
			$key = substr($key, 0, 14) . sprintf('%02d', $mm - $mm % 2);
		}
		my $provider = $r->{'provider'} // '';
		my $tokens = $r->{'tokens'} || 0;
		my $bucket = $map{$provider}->{$key} ||= { tokens => 0, calls => 0, models => {} };
		$bucket->{'tokens'} += $tokens;
		$bucket->{'calls'} += ($r->{'calls'} || 0);
		my $model = $r->{'model'} // '';
		$bucket->{'models'}->{$model} = ($bucket->{'models'}->{$model} || 0) + $tokens if length $model;
	}
	return \%map;
}

# The ledger's tokens split by provider and role, so the chart can say who spent
# them. A role that was never named is its own '' bucket. The same eval guard as
# ai_spend_buckets keeps a pre-migration database from taking the panel down.
sub ai_spend_roles {
	my ($since_key) = @_;
	$since_key = '' unless defined $since_key;
	my $rows = eval {
		&subs::db_query('select provider, role, sum(tokens_in + tokens_out) as tokens from ai_spend where minute >= ? group by provider, role', $since_key)->hashes;
	} || [];
	my %map;
	foreach my $r ( @{$rows} ) {
		$map{ $r->{'provider'} // '' }->{ $r->{'role'} // '' } = $r->{'tokens'} || 0;
	}
	return \%map;
}

# One wall-clock minute key ('YYYY-MM-DD HH:MM', in this machine's own time)
# as epoch ms. The key is local, so it is rebuilt as local time; an instant like
# that reads back to the same minute. Undefined for anything else.
sub ai_spend_minute_ms {
	my ($key) = @_;
	return undef unless defined $key && $key =~ /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d)$/;
	my $t = POSIX::mktime(0, $5, $4, $3, $2 - 1, $1 - 1900);
	return (defined $t && $t >= 0) ? $t * 1000 : undef;
}

# The earliest minute the ledger knows, in epoch ms, so the chart can tell a
# bar that predates the ledger apart from a bar that genuinely spent nothing.
# Undefined when the ledger is empty.
sub ai_spend_since {
	my $row = eval { &subs::db_query('select min(minute) as m from ai_spend where minute is not null and minute != ?', '')->hashes->[0] } || {};
	return &ai_spend_minute_ms($row->{'m'});
}

# How long two calls may be apart and still count as one stretch of use. A
# person thinking between turns, or a slow local model, leaves gaps; a coffee
# break does not. Above this a new session starts, so the chart can say "two
# hours in use over four sessions" rather than reading every call as its own
# minute of work.
our $AI_SPEND_SESSION_GAP_MS = 15 * 60 * 1000;

# How long the agents were actually in use in a window. The ledger has one row
# per model call with the minute it ran, so a session is the run of calls with
# no gap wider than $AI_SPEND_SESSION_GAP_MS: its span is the last call's minute
# minus the first's, plus the minute the last call occupies. A lone call is one
# minute. The same arithmetic runs per provider (a session may span roles) and
# per role (the agents the person actually talked to), so the panel can put
# money beside time rather than only beside the calendar.
#
# Returns provider -> { active_ms, sessions, calls, tokens, roles -> role -> the
# same shape }, plus `all` for every provider's minutes together. An absent
# table (a database that has not migrated yet) reads as no sessions.
sub ai_spend_sessions {
	my ($since_key, $gap_ms) = @_;
	$since_key = '' unless defined $since_key;
	$gap_ms = $AI_SPEND_SESSION_GAP_MS unless defined $gap_ms && $gap_ms =~ /^\d+$/ && $gap_ms > 0;
	my $rows = eval {
		&subs::db_query('select provider, role, minute, sum(tokens_in + tokens_out) as tokens, count(*) as calls from ai_spend where minute >= ? group by provider, role, minute', $since_key)->hashes;
	} || [];
	my (%providers, %all_minutes);
	foreach my $r ( @{$rows} ) {
		my $ms = &ai_spend_minute_ms($r->{'minute'});
		next unless defined $ms;
		my $provider = $r->{'provider'} // '';
		my $role = $r->{'role'} // '';
		my $tokens = $r->{'tokens'} || 0;
		my $calls = $r->{'calls'} || 0;
		my $p = $providers{$provider} ||= { minutes => {}, roles => {}, tokens => 0, calls => 0 };
		$p->{'minutes'}->{$ms} = 1;
		$p->{'tokens'} += $tokens;
		$p->{'calls'} += $calls;
		my $role_row = $p->{'roles'}->{$role} ||= { minutes => {}, tokens => 0, calls => 0 };
		$role_row->{'minutes'}->{$ms} = 1;
		$role_row->{'tokens'} += $tokens;
		$role_row->{'calls'} += $calls;
		$all_minutes{$ms} = 1;
	}
	my $span = sub {
		my ($minutes) = @_;
		my @m = sort { $a <=> $b } keys %{$minutes};
		return { active_ms => 0, sessions => 0 } unless @m;
		my ($active, $sessions) = (0, 0);
		my ($start, $prev) = ($m[0], $m[0]);
		for my $i ( 1 .. $#m ) {
			my $t = $m[$i];
			if ($t - $prev > $gap_ms) {
				$active += $prev - $start + 60_000;
				$sessions++;
				$start = $t;
			}
			$prev = $t;
		}
		$active += $prev - $start + 60_000;
		$sessions++;
		return { active_ms => $active, sessions => $sessions };
	};
	my %out;
	foreach my $provider ( keys %providers ) {
		my $p = $providers{$provider};
		my $own = $span->($p->{'minutes'});
		my %roles;
		foreach my $role ( keys %{ $p->{'roles'} } ) {
			my $r = $p->{'roles'}->{$role};
			$roles{$role} = { %{ $span->($r->{'minutes'}) }, tokens => $r->{'tokens'}, calls => $r->{'calls'} };
		}
		$out{$provider} = {
			%{$own}, roles => \%roles,
			tokens => $p->{'tokens'}, calls => $p->{'calls'},
		};
	}
	return { providers => \%out, all => $span->(\%all_minutes) };
}

# The ledger grows one row per call, so it needs a prune. Legacy rows from the
# hourly ledger have no minute (only the old hour), and an hour key sorts by its
# date first, so they are aged out on the day bound; without this they would
# never be pruned. A failure is reported as 0, not as a quiet success.
sub ai_spend_prune {
	my ($days) = @_;
	$days = 40 unless defined $days && $days =~ /^\d+$/ && $days > 0;
	my $before = &ai_spend_minute_key(&subs::rightNow() - $days * 86400000);
	my $before_day = substr($before, 0, 10);
	my $res = eval {
		&subs::db_query(
			"delete from ai_spend where (minute is not null and minute != '' and minute < ?) or ((minute is null or minute = '') and hour is not null and hour != '' and hour < ?)",
			$before, $before_day
		);
	};
	# The locator's rows share the same window: the panel only reads today, so an
	# older row is dead weight that would otherwise sync forever. Its own failure
	# is not the AI ledger's failure.
	eval {
		&subs::db_query(
			"delete from where_calls where minute is not null and minute != '' and minute < ?",
			$before
		);
	};
	return 0 unless $res;
	my $deleted = eval { $res->rows };
	return defined $deleted ? ($deleted + 0) : 1;
}

1;
